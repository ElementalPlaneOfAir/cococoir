# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — L2 test: cocococoir-edge control plane + forwarder over WG.
#
# Two-VM nixosTest exercising the *current* edge model (ADR-025):
# the edge box is Redis-driven, binds per-customer IPv6 /128s with
# IPV6_FREEBIND, and has no config file. The edge binary runs via a
# systemd unit mirroring remote-infra/system-manager/edge.nix (the box
# in production is a stock Debian host managed by system-manager, not a
# NixOS `services.cococoir-edge` module — that module was deleted).
#
# The full path under test:
#
#   curl (inside edge, to its own customer /128 via a lo route)
#     -> cocococoir-edge forwarder, [2001:db8:1::2]:80 (IPV6_FREEBIND)
#       -> WireGuard tunnel (10.10.0.0/24)
#         -> cocococoir-client forwarder, 10.10.0.2:80 (wg0)
#           -> 127.0.0.1:80 (python3 -m http.server, Caddy stand-in)
#
# The customer is created by a real `POST /signup` on the edge's control
# plane (bearer admin key), which allocates the /128, generates the
# customer's WG keypair, adds the peer to the edge's wg0, and binds the
# forwarder live. The customer box is wired *dynamically* in the test
# with the signup's returned key, because the client's wg0 private key
# only exists once signup has run.
#
# Honest limits (documented, not hidden):
#   - The curl originates inside the edge VM at a lo-routed /128, not
#     from the internet. Two-node nixosTest has no IPv6 transit between
#     VMs. What IS real: the /128 FREEBIND bind, the WG tunnel, the
#     customer box forwarder, and the local HTTP handoff.
#   - DNS is throwaway (non-fatal): signup's AAAA upsert + the reconcile
#     loop fail loudly and are logged; they cannot take the edge down.
#   - Redis is nixpkgs `services.redis`, not the edge.nix custom AOF
#     unit; the edge connects to the same 127.0.0.1:6379 either way.
#
# The L1 tripwire (vmtest-wiring) and L0 unit tests cover wiring and the
# forwarder in isolation; this test is the only check that proves the
# real signup -> /128 -> WG -> box data path end to end.
{pkgs, cococoirPkg, ...}:
let
  fixtures = ./fixtures;
  # Throwaway edge wg0 key (the edge overwrites it at boot via
  # install_edge_identity). Inline so it lands in the store path the VM
  # sees. The real WG identity is generated + persisted in Redis.
  edgePublic = pkgs.lib.strings.trim (builtins.readFile (fixtures + "/edge-public"));
  edgePrivate = pkgs.lib.strings.trim (builtins.readFile (fixtures + "/edge-private"));
  # Throwaway client wg0 key used only so 10.10.0.2 is local at boot (so
  # the forwarder binds); the test swaps in the signup's real key after
  # /signup returns it.
  clientPrivate = pkgs.lib.strings.trim (builtins.readFile (fixtures + "/client-private"));

  # The five boot secrets the edge requires (secret.rs panics if any is
  # absent). DNS_* are throwaway — DNS is non-fatal here. ROOT_DOMAIN is
  # the customer hostname suffix. ADMIN_KEY_HASH is sha256("test-admin-key")
  # = 944650a7...; the testScript signs up with `Bearer test-admin-key`.
  edgeSecretspec = ''
    [project]
    name = "cococoir-edge"
    revision = "1.0"

    [profiles.default]
    DNS_ZONE_ID = { description = "Hetzner DNS zone id", required = true }
    DNS_ZONE_NAME = { description = "Hetzner DNS zone apex", required = true }
    DNS_TOKEN = { description = "Hetzner DNS API token", required = true }
    ROOT_DOMAIN = { description = "Root domain", required = true }
    ADMIN_KEY_HASH = { description = "SHA-256 hex of the admin API key", required = true }
  '';
  edgeEnv = ''
    DNS_ZONE_ID=test-zone
    DNS_ZONE_NAME=example.net
    DNS_TOKEN=test-token
    ROOT_DOMAIN=edge-test.local
    ADMIN_KEY_HASH=944650a7cd0f9e14d5c4fb15edbffb7fa45fb9ed36a4fa9be3d7e5476ae51bd9
  '';

  # The edge box's routed subnet. 2001:db8::/32 is the documentation
  # range; customer 1 is host 2 -> 2001:db8:1::2. The /64 is never added
  # to an interface — the forwarder binds each customer /128 via
  # IPV6_FREEBIND, and the test routes it to loopback to reach it.
  subnet = "2001:db8:1::/64";
in {
  edge-forward = pkgs.testers.nixosTest {
    name = "cococoir-edge-forward";

    nodes = {
      edge = {lib, ...}: {
        # The edge box in production is stock Debian + system-manager. We
        # don't have a NixOS `services.cococoir-edge` module, so this node
        # reproduces the edge.nix unit shape directly: the binary, Redis,
        # wg0, and the boot secrets.

        environment.systemPackages = with pkgs; [
          wireguard-tools # RealWgClient shells out to `wg set wg0 ...`
          curl
          jq
          iproute2
        ];

        # Redis — the edge's store. nixpkgs services.redis binds
        # 127.0.0.1:6379, matching the edge's default --redis-url.
        services.redis.servers."".enable = true;

        # wg0 up at boot with a throwaway key; the edge overwrites the
        # key via install_edge_identity once it starts.
        networking.wireguard.interfaces.wg0 = {
          privateKey = edgePrivate;
          listenPort = 51820;
          ips = ["10.10.0.1/24"];
        };

        # Accept WG handshakes from the customer box.
        networking.firewall.allowedUDPPorts = [51820];

        # Boot secrets (secret.rs resolves them from /etc/cococoir/).
        environment.etc."cococoir/secretspec.toml".text = edgeSecretspec;
        environment.etc."cococoir/edge.env".text = edgeEnv;

        # The edge service, mirroring edge.nix's unit. WorkingDirectory
        # + EnvironmentFile mirror the SDK's resolution path.
        systemd.services.cococoir-edge = {
          description = "cococoir edge (L2 test) — forwarder + control plane";
          after = ["network-online.target" "wireguard-wg0.service" "redis.service"];
          wants = ["network-online.target" "wireguard-wg0.service" "redis.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${cococoirPkg}/bin/cococoir-edge --subnet ${subnet} --wg-subnet 10.10.0.0/24 --redis-url redis://127.0.0.1:6379 --api-addr 0.0.0.0:8081";
            WorkingDirectory = "/etc/cococoir";
            EnvironmentFile = "/etc/cococoir/edge.env";
            # NixOS systemd units don't inherit environment.systemPackages
            # PATH (unlike the Debian box edge.nix targets). The edge
            # shells out to `wg set wg0 ...`, so put wireguard-tools on
            # this unit's PATH (systemd sets PATH via Environment, not a
            # Path= directive).
            Environment = ["PATH=${lib.makeBinPath [pkgs.wireguard-tools]}"];
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
          };
        };
      };

      client = {lib, ...}: {
        # The customer box. Its wg0 is NOT brought up at boot: the
        # client's private key only exists after signup. So boot runs
        # only the local HTTP stand-in; the test brings up wg0 with the
        # signup key and starts the forwarder unit manually (wantedBy =
        # []), avoiding a bind race (the forwarder would retry 10.10.0.2:80
        # forever before the address exists).

        environment.systemPackages = with pkgs; [
          wireguard-tools
          curl
          iproute2
        ];

        # Open the WG-side TCP port. NixOS's default firewall rejects
        # incoming TCP on wg0; the client forwarder binds 10.10.0.2:80 to
        # receive forwarded traffic from the edge.
        networking.firewall.allowedTCPPorts = [80];

        # wg0 up at boot with a THROWAWAY key (the real customer key only
        # exists after /signup). The throwaway key exists only so
        # 10.10.0.2 is local at boot and the forwarder binds cleanly;
        # after signup the test swaps in the real key + edge peer via
        # `wg set`. The throwaway edgePublic peer is replaced then too.
        networking.wireguard.interfaces.wg0 = {
          privateKey = clientPrivate;
          ips = ["10.10.0.2/24"];
          peers = [
            {
              publicKey = edgePublic;
              endpoint = "edge:51820";
              allowedIPs = ["10.10.0.1/32"];
              persistentKeepalive = 25;
            }
          ];
        };

        # Client config: bind the customer's WG IP -> local service.
        environment.etc."cococoir-client.json".text = builtins.toJSON {
          forwards = [
            {
              listen_addr = "10.10.0.2:80";
              proto = "tcp";
              dest_addr = "127.0.0.1:80";
            }
          ];
        };

        # Stand-in for Caddy: a python3 http.server bound to 127.0.0.1:80,
        # serving a fixed HTML file. Auto-started at boot.
        systemd.services.test-http = let
          responseDir = pkgs.runCommand "cococoir-test-response" {} ''
            mkdir -p $out
            cat > $out/index.html <<'EOF'
            <!DOCTYPE html>
            <html><body><h1>cococoir test response</h1></body></html>
            EOF
          '';
        in {
          wantedBy = ["multi-user.target"];
          after = ["network.target"];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 80 --bind 127.0.0.1 --directory ${responseDir}";
          serviceConfig.Restart = "always";
        };

        # The client forwarder — auto-starts at boot, AFTER wg0 is up (so the
        # 10.10.0.2:80 bind has an address). The throwaway wg0 key means
        # the tunnel isn't authenticated yet, but the bind succeeds; the
        # test swaps in the real key without touching this service.
        systemd.services.cococoir-client = {
          description = "cococoir client (L2 test) — forwarder";
          after = ["network-online.target" "wireguard-wg0.service"];
          wants = ["network-online.target" "wireguard-wg0.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${cococoirPkg}/bin/cococoir-client -config /etc/cococoir-client.json -log-format text -health-addr 127.0.0.1:9090";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };

    testScript = ''
      import json

      # Boot order: both VMs up; edge needs wg0 + Redis + the edge
      # binary; client needs the local HTTP stand-in.
      edge.wait_for_unit("multi-user.target")
      client.wait_for_unit("multi-user.target")
      edge.wait_for_unit("wireguard-wg0.service")
      edge.wait_for_unit("redis.service")
      edge.wait_for_unit("cococoir-edge.service")
      client.wait_for_unit("wireguard-wg0.service")
      client.wait_for_unit("cococoir-client.service")
      client.wait_for_unit("test-http.service")

      # Sanity: the python server is up and serves the fixture.
      client.succeed("curl -sf http://127.0.0.1:80/ | grep -q 'cococoir test response'")

      # The edge's control-plane API is up.
      edge.wait_for_open_port(8081)

      # Real signup via the control plane (bearer admin key). Allocates
      # the /128, generates the customer's WG keypair, adds the WG peer
      # to wg0, binds the /128 forward. DNS fails (throwaway) — non-fatal.
      signup = edge.succeed(
          "curl -sf -H 'Authorization: Bearer test-admin-key' "
          "-H 'Content-Type: application/json' "
          "-d '{\"username\":\"alice\"}' "
          "http://127.0.0.1:8081/signup"
      )
      data = json.loads(signup)
      customer_ipv6 = data["customer"]["ipv6"]
      customer_wgip = data["customer"]["wg_ip"]
      wg_private_key = data["wg_private_key"]
      edge_public_key = data["edge_public_key"]

      # The edge forwarder must have bound the customer's /128 live
      # (IPV6_FREEBIND). Prove it via the /status endpoint before we
      # depend on it. (listen_addr is "[<ipv6>]:80" — grep the bracketed
      # address, not "<ipv6>:80".) The edge serves /status on the same
      # 8081 handler as the API.
      edge.wait_until_succeeds(
          "curl -sf http://127.0.0.1:8081/status | grep -q '[{}]'".format(customer_ipv6)
      )

      # Wire the customer box with the signup's real keypair: swap the wg0
      # private key + peer on the live interface (the forwarder has been
      # bound since boot and keeps running). Remove the throwaway peer;
      # add the edge's real public key as the tunnel peer.
      client.succeed(
          "printf '%s\n' '{}' > /tmp/cococoir-client.priv\n".format(wg_private_key)
          + "wg set wg0 private-key /tmp/cococoir-client.priv\n"
          + "wg set wg0 peer {} allowed-ips 10.10.0.1/32 endpoint edge:51820 persistent-keepalive 25\n".format(edge_public_key)
          + "wg set wg0 peer {} remove\n".format("${edgePublic}")
          + "rm /tmp/cococoir-client.priv"
      )
      client.wait_until_succeeds(
          "curl -sf http://127.0.0.1:9090/status | grep -q '" + customer_wgip + ":80'"
      )

      # Route the edge's own customer /128 to loopback so the FREEBIND
      # socket is reachable from inside the edge VM (no IPv6 transit
      # between nixosTest VMs).
      edge.succeed("ip -6 route add {} dev lo".format(customer_ipv6))

      # THE TEST: from the edge, hit the customer /128 -> edge forwarder
      # -> WireGuard tunnel -> customer box forwarder -> local http. The
      # HTML body is the assertion.
      output = edge.succeed("curl -g -sf http://[{}]:80/".format(customer_ipv6))
      assert "cococoir test response" in output, "unexpected response: {!r}".format(output)

      # Health endpoints respond on both boxes (edge on the merged 8081
      # handler; the client still has its own on 9090).
      edge.wait_for_open_port(8081)
      client.wait_for_open_port(9090)
      assert "ok" in edge.succeed("curl -sf http://127.0.0.1:8081/healthz"), "edge /healthz"
      assert "ok" in client.succeed("curl -sf http://127.0.0.1:9090/healthz"), "client /healthz"

      # /status: the edge shows the bound /128 forward; the client shows
      # its WG-side forward.
      edge_status = edge.succeed("curl -sf http://127.0.0.1:8081/status")
      assert customer_ipv6 in edge_status, "edge status missing /128 forward"
      assert '"bound": true' in edge_status, "edge forward not bound"
      client_status = client.succeed("curl -sf http://127.0.0.1:9090/status")
      assert customer_wgip + ":80" in client_status, "client status missing wg forward"

      print("edge-forward: PASS")
    '';
  };
}