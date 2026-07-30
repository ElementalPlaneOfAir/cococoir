# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/jellyfin — Jellyfin media server.
#
# 4-option contract (per PLAN.md "Services" + ADR-004; see
# services/_contract.nix for the shared factory):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → 403
#   bucket    — Garage bucket that backs the media library
#
# What the factory gives us for free:
#   - the four options above + the hidden `port`, `healthUrl`,
#     `journald.units` options
#   - assertions (public → caddy, bucket → storage, domain set)
#   - the Caddy vhost with the right `tls` directive from
#     cococoir.tls and the right `reverse_proxy` / 403
#
# What this module adds:
#   - activates nixpkgs' services.jellyfin
#   - activates jellarr for declarative config (users, libraries,
#     plugins, startup-wizard skip). Per AGENTS.md §
#     "jellyfin + jellarr" is one toggle.
#   - declares the jellyfin system user (with `render`/`video`
#     extra groups for HW transcode)
#   - waits on the FUSE mount of the backing bucket
#   - auto-declares the bucket + FUSE mount under
#     cococoir.storage.* so the user does not have to wire
#     storage separately
#
# Limitation: nixpkgs' services.jellyfin does not expose a bind
# address or port option. Jellyfin's runtime default is bind on
# 0.0.0.0:8096. We set openFirewall = false (the security
# boundary is the Caddy vhost, not the Jellyfin port). If a
# future user changes the port in Jellyfin's admin UI, they must
# also override the hidden `port` option here so Caddy and the
# prober keep up.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "jellyfin";
  description = "Jellyfin media server";
  defaultPort = 8096;
  defaultHealthPath = "/health";
  defaultBucket = "media";
  defaultMount = "/media/entertain";
  extraConfig = {cfg, lib, options, ...}: let
    base = {
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
        ["cococoir-fuse-${cfg.bucket}.service"];

      cococoir.storage.buckets.${cfg.bucket}.replicationFactor = 1;
      cococoir.storage.mounts.${cfg.bucket} = {
        bucket = cfg.bucket;
        mountPoint = "/media/entertain";
      };
    };
  in
  lib.recursiveUpdate base (lib.optionalAttrs (options.services ? jellarr) {
    services.jellarr = {
      enable = true;
      user = "jellyfin";
      group = "jellyfin";
      bootstrap = {
        enable = true;
        apiKeyFile = "/var/lib/jellarr/api-key";
      };
      environmentFile = "/var/lib/jellarr/jellarr.env";
      config = {
        version = 1;
        base_url = "http://127.0.0.1:8096";
        system = {};
        startup.completeStartupWizard = true;
        library.virtualFolders = lib.mkDefault [
          {
            name = "Entertainment";
            collectionType = "movies";
            libraryOptions.pathInfos = [
              { path = "/media/entertain"; }
            ];
          }
        ];
      };
    };

    systemd.services.cococoir-jellarr-api-key = {
      description = "Generate jellarr API key (idempotent)";
      wantedBy = ["multi-user.target"];
      before = ["jellarr-api-key-bootstrap.service" "jellarr.service"];
      after = ["systemd-tmpfiles-setup.service"];
      path = [pkgs.openssl];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "gen-jellarr-api-key" ''
          set -euo pipefail
          if [ ! -f /var/lib/jellarr/api-key ]; then
            umask 077
            openssl rand -hex 32 > /var/lib/jellarr/api-key
          fi
          printf 'JELLARR_API_KEY=%s\n' "$(cat /var/lib/jellarr/api-key)" \
            > /var/lib/jellarr/jellarr.env
          chmod 0600 /var/lib/jellarr/jellarr.env
        '';
      };
    };

    systemd.services.jellarr-api-key-bootstrap = {
      after = ["cococoir-jellarr-api-key.service"];
      requires = ["cococoir-jellarr-api-key.service"];
    };

    systemd.services.jellarr = {
      wantedBy = ["multi-user.target"];
      after = ["cococoir-jellarr-api-key.service"];
      requires = ["cococoir-jellarr-api-key.service"];
    };
  });
}
