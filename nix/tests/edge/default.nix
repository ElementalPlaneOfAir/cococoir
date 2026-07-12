# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — L2 test: cococoir-edge forwarder over WireGuard.
#
# Two-VM nixosTest that exercises the full L4-forwarder-over-WG path:
#
#   curl (on edge)
#     -> cococoir-edge listener (192.168.1.10:80, per-IP bind)
#       -> WireGuard tunnel (10.10.0.0/24)
#         -> cococoir-client listener (10.10.0.2:80)
#           -> 127.0.0.1:80 (python3 -m http.server)
#
# If the test passes, the data path works: a per-IP-bound listener on
# the VPS can be reached, forwarded over WireGuard to the customer
# box, and handed off to a local service. This is the core of the
# cococoir networking model, and the per-IP bind exercises the v0.5
# PR 1 forwarder's per-IP code path (retry-with-backoff on the
# initial bind, graceful shutdown). The forwarder waits for the IP
# to appear on the local interface before binding, so the test adds
# 192.168.1.10 as a secondary address on eth1.
#
# What this test does NOT cover (intentional, v0/v0.5):
#   - Multi-customer per-IP binding on a single VPS (v0.5 PR 2
#     brings Hetzner IP provisioning; this test has a single
#     bind, but the forwarder code path is the same).
#   - TLS (Caddy lives on the customer box and is not in this test;
#     the v0.5 Caddy module will add a TLS-terminating test).
#   - The control channel between edge and client (v0.5 PR 4).
#   - The probe system (v0.5 PR 4).
#
# Why this is the right v0 test: the "given 3 inputs, does the system
# work end-to-end" question (PLAN_2.md, "Why 3 inputs, not zero config")
# starts with the network. If the forwarder can't carry a single
# HTTP request from the public listener to a local service, nothing
# else matters.
{pkgs, ...}:
let
  fixtures = ./fixtures;
  # Inline the keys as strings. The fixtures/ paths are outside the
  # Nix store, so they aren't visible inside the nixosTest VM. Using
  # `privateKey` (inline) and `publicKey` (inline) puts the key bytes
  # into the Nix store path that the VM does see. Acceptable for a
  # test: the keys are throwaway fixtures, not real production keys.
  # (Real production wires the key from sops-nix or age, which makes
  # the secret available in the VM's filesystem at boot.)
  edgePublic = builtins.readFile (fixtures + "/edge-public");
  clientPublic = builtins.readFile (fixtures + "/client-public");
  edgePrivate = builtins.readFile (fixtures + "/edge-private");
  clientPrivate = builtins.readFile (fixtures + "/client-private");
in {
  edge-forward = pkgs.testers.nixosTest {
    name = "cococoir-edge-forward";

    nodes = {
      edge = {...}: {
        imports = [
          (import ../../nixos-modules)
        ];

        services.cococoir-edge.enable = true;

        # Generate /etc/cococoir-edge.json from a Nix attrset. The
        # cococoir-edge module's configFile option defaults to this
        # path, so no explicit override is needed. Same shape as the
        # operator workflow in production: define forwards in Nix,
        # serialize to JSON, drop it at the standard path.
        #
        # The forwarder binds to 192.168.1.10:80 (per-IP, not
        # 0.0.0.0) so this test exercises the v0.5 PR 1 per-IP
        # binding code path. 192.168.1.10 is assigned to eth1
        # below as a /32 secondary.
        environment.etc."cococoir-edge.json".text = builtins.toJSON {
          forwards = [
            {
              listen_addr = "192.168.1.10:80";
              proto = "tcp";
              dest_addr = "10.10.0.2:80";
            }
          ];
        };

        # Add 192.168.1.10 as a /32 secondary on the user-network
        # interface. nixosTest's default addressing puts a different
        # 192.168.1.x address on eth1 already; this is a second
        # local IP that the forwarder binds to. The /32 prefix
        # avoids any interference with the test's own routing.
        networking.interfaces.eth1.ipv4.addresses = [
          { address = "192.168.1.10"; prefixLength = 32; }
        ];

        networking.wireguard.interfaces.wg0 = {
          privateKey = edgePrivate;
          listenPort = 51820;
          ips = ["10.10.0.1/24"];
          peers = [
            {
              publicKey = clientPublic;
              allowedIPs = ["10.10.0.2/32"];
            }
          ];
        };

        # Allow the WireGuard UDP port in from the test's virtual network.
        networking.firewall.allowedUDPPorts = [51820];
      };

      client = {...}: {
        imports = [
          (import ../../nixos-modules)
        ];

        services.cococoir-client.enable = true;

        # Same pattern as the edge: forwards in Nix, JSON-serialized
        # to /etc/cococoir-client.json (the module's configFile
        # default). Replaces the previous fixtures/client.json file.
        environment.etc."cococoir-client.json".text = builtins.toJSON {
          forwards = [
            {
              listen_addr = "10.10.0.2:80";
              proto = "tcp";
              dest_addr = "127.0.0.1:80";
            }
          ];
        };

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

        # Open the WG-side TCP port. NixOS's default firewall rejects
        # incoming TCP on the WG interface; cococoir-client binds
        # there to receive forwarded traffic from the edge. Without
        # this rule, the dial from the edge times out.
        networking.firewall.allowedTCPPorts = [80];

        # Stand-in for Caddy: a python3 http.server bound to
        # 127.0.0.1:80, serving a fixed HTML file. Replaced by the
        # real Caddy module in the v0.5 Caddy test.
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
      };
    };

    testScript = ''
      # Boot order: both VMs up, both WG interfaces up, both cococoir
      # services up, test-http listening on the client.
      edge.wait_for_unit("multi-user.target")
      client.wait_for_unit("multi-user.target")

      edge.wait_for_unit("wireguard-wg0.service")
      client.wait_for_unit("wireguard-wg0.service")

      edge.wait_for_unit("cococoir-edge.service")
      client.wait_for_unit("cococoir-client.service")

      client.wait_for_open_port(80)

      # Sanity check: the python server is up and serves the fixture.
      client.succeed("curl -sf http://127.0.0.1:80/ | grep -q 'cococoir test response'")

      # Sanity check: the WG tunnel carries traffic (ping across it).
      edge.wait_until_succeeds("ping -c 1 -W 2 10.10.0.2", timeout=10)

      # The test: from inside the edge VM, curl hits the local
      # cococoir-edge listener at 192.168.1.10:80 (per-IP bind),
      # which forwards over WG to the client, which forwards to
      # local python on 127.0.0.1:80. The HTML body is the assertion.
      output = edge.succeed("curl -sf http://192.168.1.10:80/")
      assert "cococoir test response" in output, f"unexpected response: {output!r}"

      # Health endpoint: each cococoir service exposes /healthz, /readyz,
      # /status on 127.0.0.1:9090 by default. The endpoints let a
      # misbehaving VM be inspected from the test driver (or an
      # operator) without booting the test again.
      edge.wait_for_open_port(9090)
      client.wait_for_open_port(9090)

      # /healthz is always 200 if the process is alive.
      assert "ok" in edge.succeed("curl -sf http://127.0.0.1:9090/healthz"), "edge /healthz did not return ok"
      assert "ok" in client.succeed("curl -sf http://127.0.0.1:9090/healthz"), "client /healthz did not return ok"

      # /readyz returns 200 once at least one forward is bound.
      assert edge.succeed("curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/readyz") == "200", "edge /readyz not 200"
      assert client.succeed("curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/readyz") == "200", "client /readyz not 200"

      # /status returns the full state as JSON. Assert the component
      # field and that the bind is recorded on both services.
      edge_status = edge.succeed("curl -sf http://127.0.0.1:9090/status")
      assert '"component": "cococoir-edge"' in edge_status, f"edge status missing component: {edge_status!r}"
      assert '"bound": true' in edge_status, f"edge status missing bound:true: {edge_status!r}"
      assert '"listen_addr": "192.168.1.10:80"' in edge_status, f"edge status missing per-IP listen: {edge_status!r}"

      client_status = client.succeed("curl -sf http://127.0.0.1:9090/status")
      assert '"component": "cococoir-client"' in client_status, f"client status missing component: {client_status!r}"
      assert '"bound": true' in client_status, f"client status missing bound:true: {client_status!r}"
      assert '"listen_addr": "10.10.0.2:80"' in client_status, f"client status missing WG listen: {client_status!r}"

      print("edge-forward: PASS")
    '';
  };
}
