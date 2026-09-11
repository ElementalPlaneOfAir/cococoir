# SPDX-License-Identifier: AGPL-3.0-or-later
# Fortress v2 — L2 test: cofortress-edge control plane + forwarder over WG.
#
# Two-VM nixosTest exercising the *current* edge model (ADR-025):
# the edge box is Redis-driven, binds per-customer IPv6 /128s with
# IPV6_FREEBIND, and has no config file. The edge binary runs via a
# systemd unit mirroring remote-infra/system-manager/edge.nix (the box
# in production is a stock Debian host managed by system-manager, not a
# NixOS `services.fortress-edge` module — that module was deleted).
#
# The full path under test:
#
#   curl (inside edge, to its own customer /128 via a lo route)
#     -> cofortress-edge forwarder, [2001:db8:1::2]:80 (IPV6_FREEBIND)
#       -> WireGuard tunnel (10.10.0.0/24)
#         -> cofortress-client forwarder, 10.10.0.2:80 (wg0)
#           -> 127.0.0.1:80 (python3 -m http.server, Caddy stand-in)
#
# The customer is created by a real `POST /api/wireguard/new` on the
# edge's control plane (bearer admin key), which allocates the /128, adds
# the peer to the edge's wg0, and binds the forwarder live. The customer
# box generates its OWN WG keypair (ADR-025: the edge never holds a
# customer private key), sends only the public key to
# /api/wireguard/new, and is wired *dynamically* in the test with that
# key.
#
# Honest limits (documented, not hidden):
#   - The curl originates inside the edge VM at a lo-routed /128, not
#     from the internet. Two-node nixosTest has no IPv6 transit between
#     VMs. What IS real: the /128 FREEBIND bind, the WG tunnel, the
#     customer box forwarder, and the local HTTP handoff.
#   - DNS is throwaway (non-fatal): signup's AAAA upsert + the reconcile
#     loop fail loudly and are logged; they cannot take the edge down.
#   - The coordination store is nixpkgs `services.redis` standing in
#     for the external managed store (ADR-029: prod has no local redis
#     unit); the edge connects to the same 127.0.0.1:6379 either way.
#
# The L1 tripwire (vmtest-wiring) and L0 unit tests cover wiring and the
# forwarder in isolation; this test is the only check that proves the
# real signup -> /128 -> WG -> box data path end to end.
{pkgs, fortressPkg, ...}:
let
  fixtures = ./fixtures;
  # The edge's wg0 identity: the shared store-held key (ADR-029), the
  # same shape as production's WG_PRIVATE_KEY (one key, both nodes).
  # wg0.conf carries it so the interface comes up; the edge re-installs
  # the same key at boot from edge.env via install_edge_identity — the
  # identity comes from the store, never generated in Redis.
  edgePublic = pkgs.lib.strings.trim (builtins.readFile (fixtures + "/edge-public"));
  edgePrivate = pkgs.lib.strings.trim (builtins.readFile (fixtures + "/edge-private"));

  # The six boot secrets the edge requires (secret.rs panics if any is
  # absent). DNS_* are throwaway — DNS is non-fatal here. ROOT_DOMAIN is
  # the customer hostname suffix. ADMIN_KEY_HASH is sha256("test-admin-key")
  # = 944650a7...; the testScript signs up with `Bearer test-admin-key`.
  # WG_PRIVATE_KEY is the shared identity, so the edge's public key is
  # deterministic (= edgePublic) and the client config can trust it.
  edgeSecretspec = ''
    [project]
    name = "fortress-edge"
    revision = "1.0"

    [profiles.default]
    DNS_ZONE_ID = { description = "Hetzner DNS zone id", required = true }
    DNS_ZONE_NAME = { description = "Hetzner DNS zone apex", required = true }
    DNS_TOKEN = { description = "Hetzner DNS API token", required = true }
    ROOT_DOMAIN = { description = "Root domain", required = true }
    ADMIN_KEY_HASH = { description = "SHA-256 hex of the admin API key", required = true }
    WG_PRIVATE_KEY = { description = "Shared edge wg0 private key", required = true }
    REDIS_URL = { description = "Shared external coordination store URL", required = true }
  '';
  edgeEnv = ''
    DNS_ZONE_ID=test-zone
    DNS_ZONE_NAME=example.net
    DNS_TOKEN=test-token
    ROOT_DOMAIN=edge-test.local
    ADMIN_KEY_HASH=944650a7cd0f9e14d5c4fb15edbffb7fa45fb9ed36a4fa9be3d7e5476ae51bd9
    WG_PRIVATE_KEY=${edgePrivate}
    REDIS_URL=redis://127.0.0.1:6379
  '';

  # The edge box's routed subnet. 2001:db8::/32 is the documentation
  # range; customer 1 is host 2 -> 2001:db8:1::2. The /64 is never added
  # to an interface — the forwarder binds each customer /128 via
  # IPV6_FREEBIND, and the test routes it to loopback to reach it. NOTE:
  # 2001:db8:1::2 intentionally equals the edge's OWN eth1 IPv6 in the
  # nixosTest network (edge = 192.168.1.2 / 2001:db8:1::2) — that is what
  # makes the FREEBIND-bound /128 receive connections in the VM; a truly
  # non-local /128 gets RST (connection refused).
  subnet = "2001:db8:1::/64";
in {
  edge-forward = pkgs.testers.nixosTest {
    name = "fortress-edge-forward";

    nodes = {
      edge = {lib, ...}: {
        # The edge box in production is stock Debian + system-manager. We
        # don't have a NixOS `services.fortress-edge` module, so this node
        # reproduces the edge.nix unit shape directly: the binary, Redis,
        # wg0, and the boot secrets.

        environment.systemPackages = with pkgs; [
          wireguard-tools # RealWgClient shells out to `wg set wg0 ...`
          curl
          jq
          iproute2
        ];

        # The coordination store is the LOCAL stand-in for the external
        # managed Redis (nixpkgs services.redis binds 127.0.0.1:6379);
        # the edge binary takes --redis-url like a dev/test override.
        services.redis.servers."".enable = true;

        # wg0 up at boot with the shared identity; the edge re-installs
        # the same key from edge.env via install_edge_identity.
        networking.wireguard.interfaces.wg0 = {
          privateKey = edgePrivate;
          listenPort = 51820;
          ips = ["10.10.0.1/24"];
        };

        # Accept WG handshakes from the customer box.
        networking.firewall.allowedUDPPorts = [51820];

        # Boot secrets (secret.rs resolves them from /etc/fortress/).
        environment.etc."fortress/secretspec.toml".text = edgeSecretspec;
        environment.etc."fortress/edge.env".text = edgeEnv;

        # The edge service, mirroring edge.nix's unit. WorkingDirectory
        # + EnvironmentFile mirror the SDK's resolution path.
        systemd.services.fortress-edge = {
          description = "fortress edge (L2 test) — forwarder + control plane";
          after = ["network-online.target" "wireguard-wg0.service" "redis.service"];
          wants = ["network-online.target" "wireguard-wg0.service" "redis.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${fortressPkg}/bin/fortress-edge --subnet ${subnet} --wg-subnet 10.10.0.0/24 --redis-url redis://127.0.0.1:6379 --api-addr 0.0.0.0:8081";
            WorkingDirectory = "/etc/fortress";
            EnvironmentFile = "/etc/fortress/edge.env";
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
        # (client-owned tunnel, ADR-025): cofortress-client generates +
        # persists its own keypair under /var/lib/fortress, configures the
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
        # edge_pubkey is the shared identity's public key — deterministic
        # because WG_PRIVATE_KEY in edge.env pins it (ADR-029).
        # edge_endpoint is the edge's IPv4, NOT the hostname: nixosTest
        # resolves node names to their IPv6 (2001:db8:1::N) and a WG
        # handshake to that IPv6 never gets through to the edge's wg0
        # (pre-existing, reproduced with the original test too). The
        # vlan IPv4 is stable per node order (edge = node 2).
        environment.etc."fortress-client.json".text = builtins.toJSON {
          tunnel = {
            ip = "10.10.0.2";
            prefix = 24;
            edge_pubkey = edgePublic;
            edge_endpoint = "192.168.1.2:51820";
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
          responseDir = pkgs.runCommand "fortress-test-response" {} ''
            mkdir -p $out
            cat > $out/index.html <<'EOF'
            <!DOCTYPE html>
            <html><body><h1>fortress test response</h1></body></html>
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
        # StateDirectory=fortress creates the writable key dir;
        # path gives `wg`/`ip` on the unit's PATH.
        systemd.services.fortress-client = {
          description = "fortress client (L2 test) — tunnel + forwarder";
          after = ["network-online.target"];
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];
          # The client shells out to `ip`/`wg`; give it them on PATH.
          path = [pkgs.iproute2 pkgs.wireguard-tools];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${fortressPkg}/bin/fortress-client -config /etc/fortress-client.json -log-format text -health-addr 127.0.0.1:9090";
            Restart = "on-failure";
            RestartSec = 5;
            StateDirectory = "fortress";
          };
        };
      };
    };

    testScript = ''
      import json

      # Boot order: both VMs up; edge needs wg0 + Redis + the edge
      # binary; client needs the local HTTP stand-in. The client's wg0 is
      # brought up by cofortress-client itself (client-owned tunnel).
      edge.wait_for_unit("multi-user.target")
      client.wait_for_unit("multi-user.target")
      edge.wait_for_unit("wireguard-wg0.service")
      edge.wait_for_unit("redis.service")
      edge.wait_for_unit("fortress-edge.service")
      client.wait_for_unit("fortress-client.service")
      client.wait_for_unit("test-http.service")
      # The client brought wg0 up with its own persisted keypair.
      client.wait_until_succeeds("ip link show wg0")

      # Sanity: the python server is up and serves the fixture.
      client.succeed("curl -sf http://127.0.0.1:80/ | grep -q 'fortress test response'")

      # The edge's control-plane API is up.
      edge.wait_for_open_port(8081)

      # The client owns wg0: it generated + persisted its own keypair at
      # boot (under /var/lib/fortress) and brought wg0 up. Read back the
      # persisted public key — the client holds the private key and sends
      # only the public key to the edge (ADR-025).
      client_pub = client.succeed("wg pubkey < /var/lib/fortress/wg-private.key").strip()

      # Real device-route creation via the control-plane API (bearer
      # admin key) with the client's public key. Allocates the /128, adds
      # the WG peer to wg0, binds the /128 forward. DNS fails
      # (throwaway) — non-fatal.
      signup = edge.succeed(
          "curl -sf -H 'Authorization: Bearer test-admin-key' "
          "-H 'Content-Type: application/json' "
          "-d '{\"username\":\"alice\",\"public_key\":\"" + client_pub + "\"}' "
          "http://127.0.0.1:8081/api/wireguard/new"
      )
      data = json.loads(signup)
      customer_ipv6 = data["customer"]["ipv6"]
      customer_wgip = data["customer"]["wg_ip"]
      edge_public_key = data["edge_public_key"]
      assert data["customer"]["wg_public_key"] == client_pub, "edge stored the client's public key"
      # The shared-identity property (ADR-029): the edge answers as the
      # deterministic key from WG_PRIVATE_KEY in edge.env — which is the
      # pubkey the client config already points at, so no peer swap is
      # needed (the edge no longer generates a fresh key per boot).
      assert edge_public_key == "${edgePublic}", "edge served the shared pubkey, got {!r}".format(edge_public_key)

      # The edge forwarder must have bound the customer's /128 live
      # (IPV6_FREEBIND). Prove it via the /api/status endpoint before we
      # depend on it. (listen_addr is "[<ipv6>]:80" — grep the bracketed
      # address, not "<ipv6>:80".) The edge serves /api/status on the
      # same 8081 handler as the API.
      edge.wait_until_succeeds(
          "curl -sf http://127.0.0.1:8081/api/status | grep -q '[{}]'".format(customer_ipv6)
      )

      # The client's wg0 peer already points at the shared pubkey
      # (edge_pubkey = edgePublic in the config, and the edge answers as
      # that exact key). Nothing to swap — but FORCE a fresh handshake:
      # the boot-time initiation was dropped (the edge had not yet added
      # this peer — signup runs later) and WireGuard won't re-fire it
      # before the data-path check. Remove + re-add kicks a new
      # initiation (the pre-T3 swap did the same); with the shared
      # identity the key is unchanged, only the handshake is re-armed.
      # The endpoint is the edge's IPv4 (192.168.1.2): nixosTest resolves
      # node names to IPv6 and a handshake to that IPv6 never reaches the
      # edge's wg0 (pre-existing, reproduced with the original test too).
      client.succeed(
          "wg set wg0 peer {} remove\n".format("${edgePublic}")
          + "wg set wg0 peer {} allowed-ips 10.10.0.0/24 endpoint 192.168.1.2:51820 persistent-keepalive 25\n".format(edge_public_key)
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
      assert "fortress test response" in output, "unexpected response: {!r}".format(output)

      # Health endpoints respond on both boxes (edge on the merged 8081
      # handler; the client still has its own on 9090).
      edge.wait_for_open_port(8081)
      client.wait_for_open_port(9090)
      assert "ok" in edge.succeed("curl -sf http://127.0.0.1:8081/api/healthz"), "edge /api/healthz"
      assert "ok" in client.succeed("curl -sf http://127.0.0.1:9090/healthz"), "client /healthz"

      # /api/status: the edge shows the bound /128 forward; the client
      # shows its WG-side forward.
      edge_status = edge.succeed("curl -sf http://127.0.0.1:8081/api/status")
      assert customer_ipv6 in edge_status, "edge status missing /128 forward"
      assert '"bound": true' in edge_status, "edge forward not bound"
      client_status = client.succeed("curl -sf http://127.0.0.1:9090/status")
      assert customer_wgip + ":80" in client_status, "client status missing wg forward"

      print("edge-forward: PASS")
    '';
  };
}