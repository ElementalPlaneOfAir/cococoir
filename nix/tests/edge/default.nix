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
# plane (bearer admin key), which allocates the /128, adds the peer to the
# edge's wg0, and binds the forwarder live. The customer box generates its
# OWN WG keypair (ADR-025: the edge never holds a customer private key),
# sends only the public key to /signup, and is wired *dynamically* in the
# test with that key.
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

      client = {lib, pkgs, ...}: {
        # The customer box. wg0 is brought up by the CLIENT process itself
        # (client-owned tunnel, ADR-025): cocococoir-client generates +
        # persists its own keypair under /var/lib/cococoir, configures the
        # interface, then the forwarder binds. No NixOS wireguard module.

        environment.systemPackages = with pkgs; [
          wireguard-tools
          curl
          iproute2
        ];

        # Open the WG-side TCP port. NixOS's default firewall rejects
        # incoming TCP on wg0; the client forwarder binds 10.10.0.2:80 to
        # receive forwarded traffic from the edge.
        networking.firewall.allowedTCPPorts = [80];

        # Client config: the tunnel section drives the client-owned wg0.
        # edge_pubkey is the throwaway fixture peer for now — the test
        # swaps it for the edge's real boot-generated pubkey after signup
        # (the edge generates a fresh key each test boot).
        environment.etc."cococoir-client.json".text = builtins.toJSON {
          tunnel = {
            ip = "10.10.0.2";
            prefix = 24;
            edge_pubkey = edgePublic;
            edge_endpoint = "edge:51820";
            edge_allowed_ips = "10.10.0.0/24";
          };
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

        # The client process — owns wg0 + the forwarder. The client brings
        # the tunnel up before the forwarder binds, so no bind race.
        # StateDirectory=cococoir creates the writable key dir;
        # path gives `wg`/`ip` on the unit's PATH.
        systemd.services.cococoir-client = {
          description = "cococoir client (L2 test) — tunnel + forwarder";
          after = ["network-online.target"];
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];
          # The client shells out to `ip`/`wg`; give it them on PATH.
          path = [pkgs.iproute2 pkgs.wireguard-tools];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${cococoirPkg}/bin/cococoir-client -config /etc/cococoir-client.json -log-format text -health-addr 127.0.0.1:9090";
            Restart = "on-failure";
            RestartSec = 5;
            StateDirectory = "cococoir";
          };
        };
      };
    };

    testScript = ''
      import json

      # Boot order: both VMs up; edge needs wg0 + Redis + the edge
      # binary; client needs the local HTTP stand-in. The client's wg0 is
      # brought up by cocococoir-client itself (client-owned tunnel).
      edge.wait_for_unit("multi-user.target")
      client.wait_for_unit("multi-user.target")
      edge.wait_for_unit("wireguard-wg0.service")
      edge.wait_for_unit("redis.service")
      edge.wait_for_unit("cococoir-edge.service")
      client.wait_for_unit("cococoir-client.service")
      client.wait_for_unit("test-http.service")
      # The client brought wg0 up with its own persisted keypair.
      client.wait_until_succeeds("ip link show wg0")

      # Sanity: the python server is up and serves the fixture.
      client.succeed("curl -sf http://127.0.0.1:80/ | grep -q 'cococoir test response'")

      # The edge's control-plane API is up.
      edge.wait_for_open_port(8081)

      # The client owns wg0: it generated + persisted its own keypair at
      # boot (under /var/lib/cococoir) and brought wg0 up. Read back the
      # persisted public key — the client holds the private key and sends
      # only the public key to the edge (ADR-025).
      client_pub = client.succeed("wg pubkey < /var/lib/cococoir/wg-private.key").strip()

      # Real signup via the control plane (bearer admin key) with the
      # client's public key. Allocates the /128, adds the WG peer to wg0,
      # binds the /128 forward. DNS fails (throwaway) — non-fatal.
      signup = edge.succeed(
          "curl -sf -H 'Authorization: Bearer test-admin-key' "
          "-H 'Content-Type: application/json' "
          "-d '{\"username\":\"alice\",\"public_key\":\"" + client_pub + "\"}' "
          "http://127.0.0.1:8081/signup"
      )
      data = json.loads(signup)
      customer_ipv6 = data["customer"]["ipv6"]
      customer_wgip = data["customer"]["wg_ip"]
      edge_public_key = data["edge_public_key"]
      assert data["customer"]["wg_public_key"] == client_pub, "edge stored the client's public key"

      # The edge forwarder must have bound the customer's /128 live
      # (IPV6_FREEBIND). Prove it via the /status endpoint before we
      # depend on it. (listen_addr is "[<ipv6>]:80" — grep the bracketed
      # address, not "<ipv6>:80".) The edge serves /status on the same
      # 8081 handler as the API.
      edge.wait_until_succeeds(
          "curl -sf http://127.0.0.1:8081/status | grep -q '[{}]'".format(customer_ipv6)
      )

      # The client's wg0 peer was configured from the config's throwaway
      # edgePub key; point it at the edge's real boot-generated pubkey
      # (the edge generates a fresh key each test boot, so the config
      # can't know it ahead of time). The client's OWN private key is
      # already on the interface — nothing to swap. The forwarder has
      # been bound since boot and keeps running.
      client.succeed(
          "wg set wg0 peer {} remove\n".format("${edgePublic}")
          + "wg set wg0 peer {} allowed-ips 10.10.0.0/24 endpoint edge:51820 persistent-keepalive 25\n".format(edge_public_key)
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