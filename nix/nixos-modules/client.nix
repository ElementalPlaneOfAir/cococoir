# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — client service module (Rust workspace).
#
# The cocococoir-client binary is the customer-box's single process: it
# runs the L4 forwarder (receiving traffic from cocococoir-edge over the
# WireGuard tunnel and forwarding to 127.0.0.1:<port> where the local
# Caddy terminates TLS) and the embedded config dashboard. The shared
# forwarder engine lives in crates/core; the client is built from the
# Rust workspace at nix/packages/cococoir.
#
# v0 scope of this module:
#   - No SIGHUP hot-reload. NixOS rebuild -> systemd restart.
#   - No WireGuard interface config. Operator wires
#     `networking.wireguard.interfaces.wg0` in the machine config
#     directly.
#   - No probe system. The client grows a probe agent in v0.5 PR 4
#     that does HTTP GETs against local services and POSTs JSON
#     summaries to the edge's collector.
#   - No control-channel client. The client grows an HTTP client in
#     v0.5 PR 4 to talk to the edge's admin API.
#
# Config schema (JSON):
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
    enable = lib.mkEnableOption "cococoir v2 client service (L4 TCP/UDP forwarder + embedded dashboard on the customer box)";

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
    systemd.services.cococoir-client = {
      description = "Cococoir v2 client service — L4 TCP/UDP forwarder + embedded dashboard (customer box)";
      after = ["network-online.target" "wireguard-wg0.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/cococoir-client -config ${cfg.configFile} -log-format ${cfg.logFormat} -health-addr ${cfg.healthAddr}";
        Restart = "on-failure";
        RestartSec = 5;

        # The embedded dashboard's sqlite DB. StateDirectory creates
        # /var/lib/cococoir (root-owned) and makes it writable even with
        # ProtectSystem=strict; XDG_DATA_HOME points Db::open() there
        # (its default ~/.local/share is masked by ProtectHome).
        StateDirectory = "cococoir";
        Environment = "XDG_DATA_HOME=/var/lib/cococoir";

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
