# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Go edge service module.
#
# v0.5 PR 1: the cococoir-edge binary is now one of two entry points
# built from the consolidated nix/packages/cococoir module. The
# shared forwarder lives in nix/packages/cococoir/internal/forwarder.
# Per-IP binding, retry-with-backoff on initial bind, and graceful
# shutdown all live in the shared package; this module just installs
# the binary and runs it under systemd.
#
# v0 scope of this module:
#   - No SIGHUP hot-reload. NixOS rebuild -> systemd restart.
#   - No WireGuard interface config. Operator wires
#     `networking.wireguard.interfaces.wg0` in their machine config
#     directly. (When the credential story is solved, cococoir will
#     own the WG config too.)
#   - Per-IP listening binds are supported in the forwarder (the JSON
#     forwards list specifies listen_addr as host:port), but adding
#     the IPs to local interfaces remains an operator responsibility.
#
# Config schema (JSON, matches the Go binary in nix/packages/cococoir):
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
  edgePkg = pkgs.callPackage ../packages/cococoir {};
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
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/cococoir {}";
      description = "cococoir package. Override to point at a fork or pinned version. The systemd unit uses the `cococoir-edge` binary out of this package's bin/.";
    };

    logFormat = lib.mkOption {
      type = lib.types.enum ["text" "json"];
      default = "text";
      defaultText = lib.literalExpression "text";
      description = ''
        Structured-logging output format. "text" is the human-readable
        default; "json" emits one JSON object per record on stderr and
        is what a future telemetry pipeline (v0.5 PR 4) will ingest.
        A misconfigured value here fails the systemd unit at startup,
        not at log time.
      '';
    };

    healthAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9090";
      defaultText = lib.literalExpression "127.0.0.1:9090";
      description = ''
        Address for the /healthz, /readyz, /status HTTP endpoints.
        Default binds to localhost only — the health server is for
        local observability (operator curls, future on-box collector,
        nixosTest). Set to "0.0.0.0:9090" to expose externally, or
        "" to disable the health server entirely. A future v0.5 PR 4
        change will add a bearer-token auth mode for cross-node
        collection.
      '';
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
        ExecStart = "${cfg.package}/bin/cococoir-edge -config ${cfg.configFile} -log-format ${cfg.logFormat} -health-addr ${cfg.healthAddr}";
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