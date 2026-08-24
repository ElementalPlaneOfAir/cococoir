# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/jellyfin — Jellyfin media server.
#
# 4-option contract (per PLAN.md "Services" + ADR-004; see
# services/_contract.nix for the shared factory):
#   enable  — opt-in toggle
#   domain  — external FQDN for the Caddy vhost
#   public  — true → Caddy reverse-proxies; false → 403
#
# What the factory gives us for free:
#   - the options above + the hidden `port`, `healthUrl`,
#     `journald.units` options
#   - assertions (public → caddy, storageNeeded → storage,
#     domain set)
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
#   - auto-declares btrfs subvolumes under cococoir.storage.btrfs.*
#     so the user does not have to wire storage separately
#   - unitConfig.RequiresMountsFor on subvolume paths so Jellyfin
#     waits for the btrfs pool mount before starting
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
  storageNeeded = true;
  extraOptions = {
    mediaRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Base directory for the jellyfin media libraries (movies, shows,
        music). null = derive from the btrfs pool mountpoint
        (`<pool>/media`). Override to point at media that already lives
        elsewhere (e.g. an existing `/media/entertain`).
      '';
    };
  };
  extraConfig = {cfg, lib, options, config, ...}: let
    dataRoot = config.cococoir.storage.btrfs.pool.mountpoint;
    mediaRoot =
      if cfg.mediaRoot == null then "${dataRoot}/media" else cfg.mediaRoot;
    mediaPaths = {
      movies = "${mediaRoot}/movies";
      shows = "${mediaRoot}/shows";
      music = "${mediaRoot}/music";
      metadata = "${dataRoot}/jellyfin/metadata";
    };
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

      cococoir.storage.btrfs.subvolumes = {
        "media-movies" = {
          mountpoint = lib.mkDefault mediaPaths.movies;
          quota = "2T";
          owner = {
            user = "jellyfin";
            group = "jellyfin";
            mode = "770";
          };
        };
        "media-shows" = {
          mountpoint = lib.mkDefault mediaPaths.shows;
          quota = "2T";
          owner = {
            user = "jellyfin";
            group = "jellyfin";
            mode = "770";
          };
        };
        "media-music" = {
          mountpoint = lib.mkDefault mediaPaths.music;
          quota = "1T";
          owner = {
            user = "jellyfin";
            group = "jellyfin";
            mode = "770";
          };
        };
        "jellyfin-metadata" = {
          mountpoint = lib.mkDefault mediaPaths.metadata;
          quota = "50G";
          owner = {
            user = "jellyfin";
            group = "jellyfin";
            mode = "770";
          };
        };
      };

      systemd.services.jellyfin = {
        after = ["cococoir-btrfs-subvolumes.service"];
        requires = ["cococoir-btrfs-subvolumes.service"];
        unitConfig.RequiresMountsFor = [
          mediaPaths.movies
          mediaPaths.shows
          mediaPaths.music
          mediaPaths.metadata
        ];
      };
    };
  in
  lib.recursiveUpdate base (lib.optionalAttrs (options.services ? jellarr) {
    systemd.services.jellarr.serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
      StartLimitBurst = 10;
    };

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
            name = "Movies";
            collectionType = "movies";
            libraryOptions.pathInfos = [
              { path = mediaPaths.movies; }
            ];
          }
          {
            name = "TV Shows";
            collectionType = "tvshows";
            libraryOptions.pathInfos = [
              { path = mediaPaths.shows; }
            ];
          }
          {
            name = "Music";
            collectionType = "music";
            libraryOptions.pathInfos = [
              { path = mediaPaths.music; }
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
