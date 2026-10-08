# SPDX-License-Identifier: AGPL-3.0-or-later
# Fortress v2 — client service module (Rust workspace).
#
# The cofortress-client binary is the customer-box's single process: it
# runs the L4 forwarder (receiving traffic from cofortress-edge over the
# WireGuard tunnel and forwarding to 127.0.0.1:<port> where the local
# Caddy terminates TLS) and the embedded config dashboard. The shared
# forwarder engine lives in crates/core; the client is built from the
# Rust workspace at nix/packages/fortress.
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
#       { "listen_addr": "{tunnel_ip}:8080", "proto": "tcp", "dest_addr": "127.0.0.1:80" },
#       { "listen_addr": "{tunnel_ip}:8443", "proto": "tcp", "dest_addr": "127.0.0.1:443" }
#   ] }
# The client listens on the tunnel IP at the second port of the edge's
# `(public, client)` map (crates/controlplane `EDGE_FORWARDS`): the edge
# binds :80/:443 on the customer's /128 and forwards to :8080/:8443 on
# the tunnel IP. The ports differ so the box's Caddy can bind :80/:443
# wildcard without colliding with this forwarder (EADDRINUSE).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.fortress-client;
  clientPkg = pkgs.callPackage ../packages/fortress {};
  dashboardPortMatch = builtins.match ".*:([0-9]+)" cfg.dashboardAddr;
  dashboardPort = if dashboardPortMatch == null then null else builtins.head dashboardPortMatch;
  catalogPorts =
    lib.mapAttrsToList
    (name: s: {inherit name; port = toString s.port;})
    (lib.filterAttrs (_: s: (s.enable or false) && (s ? port)) config.fortress.services);
  portCollisions =
    builtins.filter
    (e: dashboardPort != null && e.port == dashboardPort)
    catalogPorts;
in {
  options.services.fortress-client = {
    enable = lib.mkEnableOption "fortress v2 client service (L4 TCP/UDP forwarder + embedded dashboard on the customer box)";

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/fortress-client.json";
      defaultText = lib.literalExpression "/etc/fortress-client.json";
      description = ''
        Path to client.json. Most users should generate this with
        `environment.etc."fortress-client.json".text = builtins.toJSON { ... };`
        (or `sops.templates."fortress-client.json".content = builtins.toJSON { ... };`
        if the config needs secrets). The default points at the standard
        `/etc/fortress-client.json` path produced by `environment.etc`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = clientPkg;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/fortress {}";
      description = "fortress package. Override to point at a fork or pinned version. The systemd unit uses the `fortress-client` binary out of this package's bin/.";
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

    dashboardAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:3210";
      defaultText = lib.literalExpression "127.0.0.1:3210";
      description = ''
        Address the embedded config dashboard binds. Loopback by
        default: the plane's Caddy (bound wildcard, see
        `fortress.network.caddyBindAddresses`) is the intended ingress,
        and the tunnel forwarder owns the tunnel IP, so the dashboard
        must not listen on every interface. `planes.nix`
        reverse-proxies the plane vhost here. The port is outside the
        service catalog's
        range (cryptpad owns 3000, forgejo 3001, …); a collision with
        an enabled service's port fails the assertions below at eval
        time, not at boot.
      '';
    };

    adminPasswordEnvFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing `FORTRESS_ADMIN_PASSWORD_HASH=<bcrypt-hash>`
        — the embedded dashboard's admin login (the box's control plane).
        Required: the dashboard has no unauthenticated mode, so
        `fortress-client` refuses to start without this. Keep the hash in
        a secret (sops template or a root-owned 0600 file written at
        deploy) rather than in the store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Fail at eval, not at 3am. `fortress-client` exits 1 without a
    # dashboard credential, so a config that ships without one would
    # boot a box whose control plane never starts. Catch it at
    # `nixos-rebuild` time instead.
    assertions = [
      {
        assertion = cfg.adminPasswordEnvFile != null;
        message = ''
          services.fortress-client.adminPasswordEnvFile is not set.

          The embedded dashboard is the control plane of the box and has
          no unauthenticated mode — fortress-client refuses to start
          without FORTRESS_ADMIN_PASSWORD_HASH. Point this at a file that
          carries `FORTRESS_ADMIN_PASSWORD_HASH=<bcrypt-hash>` (a sops
          template or a root-owned 0600 file), e.g.

            services.fortress-client.adminPasswordEnvFile =
              config.sops.templates."fortress-admin.env".path;
        '';
      }
      {
        assertion = dashboardPortMatch != null;
        message = ''
          services.fortress-client.dashboardAddr = ${cfg.dashboardAddr}
          is not a `host:port` address — the dashboard bind address
          must carry an explicit port.
        '';
      }
      {
        assertion = portCollisions == [];
        message = ''
          services.fortress-client.dashboardAddr (${cfg.dashboardAddr})
          shares its port with an enabled fortress service:
          ${lib.concatMapStringsSep ", " (e: "${e.name} (fortress.services.${e.name}.port = ${e.port})") portCollisions}.

          The dashboard and the service both bind loopback and one of
          them fails to start at boot. Point dashboardAddr at a free
          port — the service catalog owns 3000–8989.
        '';
      }
    ];

    systemd.services.fortress-client = {
      description = "Fortress v2 client service — L4 TCP/UDP forwarder + embedded dashboard (customer box)";
      # The client owns wg0 (client-side keygen): it brings the tunnel up
      # itself, so it no longer waits on a NixOS wireguard-wg0 unit. It
      # still needs real network-online to reach the edge.
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      # The client shells out to `ip`/`wg` to bring up wg0 (client-owned
      # tunnel); systemd's default PATH lacks /run/current-system/sw/bin.
      path = [pkgs.iproute2 pkgs.wireguard-tools];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/fortress-client -config ${cfg.configFile} -log-format ${cfg.logFormat} -health-addr ${cfg.healthAddr} -dashboard-addr ${cfg.dashboardAddr}";
        Restart = "on-failure";
        RestartSec = 5;

        # The embedded dashboard's admin password. Required — see the
        # assertion above. Fail-closed: a referenced-but-missing file
        # stops the unit rather than serving an open admin UI.
        EnvironmentFile = lib.mkIf (cfg.adminPasswordEnvFile != null) cfg.adminPasswordEnvFile;

        # The embedded dashboard's sqlite DB. StateDirectory creates
        # /var/lib/fortress (root-owned) and makes it writable even with
        # ProtectSystem=strict; XDG_DATA_HOME points Db::open() there
        # (its default ~/.local/share is masked by ProtectHome).
        StateDirectory = "fortress";
        Environment = "XDG_DATA_HOME=/var/lib/fortress";

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
