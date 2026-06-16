# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/jellyfin — Jellyfin media server.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → localNetworks 403
#   bucket    — name of the Garage bucket that backs the media library
#
# The NixOS module does not actively use the bucket: Jellyfin's library
# directories are configured at runtime in the admin UI. The `bucket`
# option exists so the module can assert the FUSE mount is declared in
# the cococoir/garage clan-service — if the user forgets the mount,
# evaluation fails with a clear error pointing at the declaration they
# need to add. The mount path can then be referenced as the library
# root in the admin UI.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cococoir.services.jellyfin;
  mount = config.cococoir.storage.derived.mounts.${cfg.bucket} or null;
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
      description = ''
        Name of the Garage bucket that backs the Jellyfin media library.
        A FUSE mount for this bucket must be declared in the
        cococoir/garage clan-service's `mounts.<name>`. The mount path
        is referenced in the Jellyfin admin UI as the library root.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mount != null;
        message = ''
          cococoir/services/jellyfin: bucket "${cfg.bucket}" has no FUSE
          mount declared in the cococoir/garage clan-service. Add an
          entry to `roles.<role>.machines.<name>.settings.mounts`:
            mounts.<name> = {
              bucket = "${cfg.bucket}";
              mountPoint = "/media/entertain";
            };
          Then point each Jellyfin library at a subdirectory of the
          mount path in the admin UI.
        '';
      }
    ];

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
