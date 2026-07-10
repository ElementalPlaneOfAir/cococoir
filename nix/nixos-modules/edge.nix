# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Go edge service module (Day 7-8).
#
# v0 scope: install the cococoir-edge binary and run it under systemd
# with a JSON config. No operator-side option tree is exposed yet
# (the customer-side WireGuard credential bootstrap is unsolved; see
# PLAN.md "Pending: WireGuard mesh topology" and the CGNAT note in
# the Day 7-8 decisions). When that's resolved, this module grows a
# `cococoir.edge.tenants.<name>` option surface.
#
# What this module does NOT do (intentional, v0):
#   - No SIGHUP hot-reload. NixOS rebuild -> systemd restart. See ADR update.
#   - No WireGuard interface config. Operator wires `networking.wireguard.interfaces.wg0`
#     in their machine config directly. (When the credential story is solved,
#     cococoir will own the WG config too.)
#   - No per-customer listening IPs. The Go program reads whatever IPs
#     are in the JSON config; the operator is responsible for adding
#     those IPs to the VPS interface.
#
# Config schema (JSON, matches the Go binary in nix/packages/edge):
#   { "forwards": [
#       { "listen_addr": "1.2.3.4:80",  "proto": "tcp", "dest_addr": "10.10.0.2:80" },
#       ...
#   ] }
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.cococoir-edge;
  edgePkg = pkgs.callPackage ../packages/edge {};
in {
  options.services.cococoir-edge = {
    enable = lib.mkEnableOption "cococoir v2 Go edge service (L4 TCP/UDP forwarder)";

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/cococoir-edge.json";
      defaultText = lib.literalExpression "/etc/cococoir-edge.json";
      description = ''
        Path to edge.json. Most users should generate this with
        `environment.etc."cococoir-edge.json".text = builtins.toJSON { ... };`
        (or `sops.templates."cococoir-edge.json".content = builtins.toJSON { ... };`
        if the config needs secrets). The default points at the standard
        `/etc/cococoir-edge.json` path produced by `environment.etc`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = edgePkg;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/edge {}";
      description = "cococoir-edge package. Override to point at a fork or pinned version.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cococoir-edge = {
      description = "Cococoir v2 edge service — L4 TCP/UDP forwarder";
      after = ["network-online.target" "wireguard-wg0.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/cococoir-edge -config ${cfg.configFile}";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening. Edge runs as root because it listens on privileged
        # ports (80, 443) — dropPrivileges would require CAP_NET_BIND_SERVICE
        # or socket-activation, deferred to v0.5.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [];
      };
    };
  };
}