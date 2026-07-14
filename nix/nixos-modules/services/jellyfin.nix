# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/jellyfin — Jellyfin media server.
#
# 4-option contract (per PLAN.md, "Services"):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → 403
#   bucket    — name of the Garage bucket that backs the library
#               (default "media"; override only to share or rename)
#
# Hidden options (not in the customer-facing contract; read by the
# cococoir-client prober/journald via Nix → JSON config):
#   port        — local bind port (default 8096)
#   healthUrl   — URL the prober GETs for liveness (default
#                 "http://127.0.0.1:8096/health")
#   journald.units — systemd units the journald tailer watches
#                    (default [ "jellyfin.service" ])
#
# Enabling this service auto-declares its bucket and FUSE mount
# under cococoir.storage.* so the user does not have to wire
# storage separately. Jellyfin's library directories are configured
# at runtime in the admin UI, pointing at the FUSE mount point.
#
# Limitation: nixpkgs' services.jellyfin does not expose a bind
# address or port option. Jellyfin's runtime default is bind on
# 0.0.0.0:8096. We set openFirewall = false (the security boundary
# is the Caddy vhost, not the Jellyfin port). If a future user
# changes the port in Jellyfin's admin UI, they must also override
# the hidden `port` option here so Caddy and the prober keep up.
{
  config,
  lib,
  ...
}: let
  cfg = config.cococoir.services.jellyfin;
  defaultBucket = "media";
  defaultMount = "/media/entertain";
  defaultPort = 8096;
in {
  options.cococoir.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "jellyfin.example.com";
      description = "External FQDN for the Jellyfin Caddy vhost.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to allow public access. `true` → Caddy reverse-proxies
        to the local Jellyfin port. `false` → Caddy returns 403.
      '';
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      default = defaultBucket;
      description = ''
        Name of the Garage bucket that backs the Jellyfin media
        library. Defaults to "${defaultBucket}"; override only to
        share a bucket with another service or to use a different
        bucket name. The FUSE mount point must be added as a
        library in the Jellyfin admin UI at runtime.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = defaultPort;
      description = ''
        Local port Jellyfin binds to. Hidden from the 4-option
        contract; override only to avoid a port conflict. Must
        match the port configured in Jellyfin's admin UI (the
        nixpkgs module does not expose this option, so a runtime
        change requires a matching config override here).
      '';
      internal = true;
    };

    healthUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString defaultPort}/health";
      description = ''
        URL the cococoir-client prober GETs to check Jellyfin's
        liveness. Default is Jellyfin's built-in /health endpoint
        (Jellyfin 10.6+, returns 200 with body "Healthy", no auth).
      '';
      internal = true;
    };

    journald.units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["jellyfin.service"];
      description = ''
        systemd units the cococoir-client journald tailer watches
        for OTEL log records.
      '';
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.cococoir.storage.enable;
        message = ''
          cococoir.services.jellyfin: storage is not enabled. Set
          cococoir.storage.enable = true (Garage + FUSE mount are
          required for the media library).
        '';
      }
    ];

    cococoir.storage.buckets.${cfg.bucket}.replicationFactor = 1;
    cococoir.storage.mounts.${cfg.bucket} = {
      bucket = cfg.bucket;
      mountPoint = defaultMount;
    };

    services.jellyfin = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
    };

    users.users.jellyfin = {
      isSystemUser = true;
      description = "Jellyfin System User";
      extraGroups = ["render" "video"];
    };

    systemd.services.jellyfin.after =
      [ "cococoir-fuse-${cfg.bucket}.service" ];

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then "reverse_proxy 127.0.0.1:${toString cfg.port}"
      else ''respond "Forbidden" 403'';
  };
}
