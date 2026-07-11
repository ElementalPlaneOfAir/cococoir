# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Go client service module.
#
# v0.5 PR 1: the cococoir-client binary is the second of two entry
# points built from the consolidated nix/packages/cococoir module.
# The shared forwarder lives in nix/packages/cococoir/internal/forwarder.
# See edge.nix for the per-IP binding, retry-with-backoff, and
# graceful shutdown notes.
#
# Runs on the customer box. The client receives L4 traffic from
# cococoir-edge over the WireGuard tunnel and forwards it to
# 127.0.0.1:<port> where the local Caddy terminates TLS. The client
# is the "second half" of the cococoir network: the edge forwards
# from the public internet to the customer box; the client forwards
# from the tunnel to the local services.
#
# v0 scope of this module:
#   - No SIGHUP hot-reload. NixOS rebuild -> systemd restart.
#   - No WireGuard interface config. Operator wires
#     `networking.wireguard.interfaces.wg0` in the machine config
#     directly. (When the credential story is solved, cococoir will
#     own the WG config too — same as edge.nix.)
#   - No probe system. The client grows a probe agent in v0.5 PR 4
#     that does HTTP GETs against local services and POSTs JSON
#     summaries to the edge's collector.
#   - No control-channel client. The client grows an HTTP client in
#     v0.5 PR 4 to talk to the edge's admin API.
#
# Config schema (JSON, matches the Go binary in nix/packages/cococoir):
#   { "forwards": [
#       { "listen_addr": "10.10.0.2:443", "proto": "tcp", "dest_addr": "127.0.0.1:443" },
#       { "listen_addr": "10.10.0.2:443", "proto": "udp", "dest_addr": "127.0.0.1:443" }
#   ] }
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.cococoir-client;
  clientPkg = pkgs.callPackage ../packages/cococoir {};
in {
  options.services.cococoir-client = {
    enable = lib.mkEnableOption "cococoir v2 Go client service (L4 TCP/UDP forwarder on the customer box)";

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/cococoir-client.json";
      defaultText = lib.literalExpression "/etc/cococoir-client.json";
      description = ''
        Path to client.json. Most users should generate this with
        `environment.etc."cococoir-client.json".text = builtins.toJSON { ... };`
        (or `sops.templates."cococoir-client.json".content = builtins.toJSON { ... };`
        if the config needs secrets). The default points at the standard
        `/etc/cococoir-client.json` path produced by `environment.etc`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = clientPkg;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/cococoir {}";
      description = "cococoir package. Override to point at a fork or pinned version. The systemd unit uses the `cococoir-client` binary out of this package's bin/.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cococoir-client = {
      description = "Cococoir v2 client service — L4 TCP/UDP forwarder (customer box)";
      after = ["network-online.target" "wireguard-wg0.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/cococoir-client -config ${cfg.configFile}";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening. Client runs as root for v0 (binding to the WG
        # interface doesn't require it, but matching the edge's
        # posture keeps the story simple; v0.5 can drop privileges
        # since the client doesn't bind privileged ports).
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [];
      };
    };
  };
}
