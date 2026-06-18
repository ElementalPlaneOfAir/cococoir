# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/jellyfin — Jellyfin media server.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → localNetworks 403
#   bucket    — name of the Garage bucket (default "media", override
#               only to use a non-default bucket name)
#
# Enabling this service auto-declares its bucket + FUSE mount in
# `cococoir.storage.*`, so the user does not need to wire up
# storage separately. The NixOS module does not actively use the
# bucket at evaluation time — Jellyfin's library directories are
# configured at runtime in the admin UI, pointing at the FUSE
# mount point. qBittorrent and other S3-backed media services
# default to the same "media" bucket so they share a single
# bucket + mount declaration.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cococoir.services.jellyfin;
  defaultBucket = "media";
  defaultMount = "/media/entertain";
in {
  options.cococoir.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External FQDN for Jellyfin (e.g. media.example.com).";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Jellyfin.";
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      default = defaultBucket;
      description = ''
        Name of the Garage bucket that backs the Jellyfin media
        library. Defaults to "${defaultBucket}"; override only to
        use a non-default bucket. Add the FUSE mount point as a
        library in the Jellyfin admin UI.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    cococoir.storage.buckets.${cfg.bucket} = { };
    cococoir.storage.mounts.${cfg.bucket} = {
      bucket = cfg.bucket;
      mountPoint = defaultMount;
    };

    services.jellyfin = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
    };

    users.groups.jellyfin = {};
    users.users.jellyfin = {
      isSystemUser = true;
      description = "Jellyfin System User";
      shell = lib.mkDefault pkgs.bash;
      extraGroups = ["render" "video"];
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:8096''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:8096
      '';
  };
}
