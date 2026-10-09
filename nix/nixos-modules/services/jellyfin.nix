# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/jellyfin — Jellyfin media server.
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
#     fortress.tls and the right `reverse_proxy` / 403
#
# What this module adds:
#   - activates nixpkgs' services.jellyfin
#   - activates jellarr for declarative config (users, libraries,
#     plugins, startup-wizard skip). Per AGENTS.md §
#     "jellyfin + jellarr" is one toggle.
#   - declares the jellyfin system user (with `render`/`video`
#     extra groups for HW transcode)
#   - auto-declares btrfs subvolumes under fortress.storage.btrfs.*
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
}: let
  mkFortressService = import ./_contract.nix {inherit lib config pkgs options;};
in
  mkFortressService {
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
    extraConfig = {
      cfg,
      lib,
      options,
      config,
      ...
    }: let
      btrfsStorage = config.fortress.storage.enable && config.fortress.storage.backend == "btrfs";
      layout = config.fortress.media.layout;
      mediaPaths = {
        inherit (layout) movies shows music metadata;
      };
      # Jellyfin scans only the `library/` subdir of each media
      # subvolume; `downloads/` (the qbittorrent staging area) stays
      # invisible to it. Downloads hardlink INTO library — same
      # subvolume, so hardlinks are possible and imports are free.
      libraryPaths = {
        inherit (layout) moviesLibrary;
        movies = layout.moviesLibrary;
        shows = layout.showsLibrary;
      };
      mediaDirs = {
        "${mediaPaths.movies}/downloads" = {
          user = "root";
          group = "root";
          mode = "770";
        };
        "${mediaPaths.movies}/library" = {
          user = "root";
          group = "root";
          mode = "770";
        };
        "${mediaPaths.shows}/downloads" = {
          user = "root";
          group = "root";
          mode = "770";
        };
        "${mediaPaths.shows}/library" = {
          user = "root";
          group = "root";
          mode = "770";
        };
      };
      base = {
        services.jellyfin = {
          enable = true;
          # For local access only I am going to enable this for the time being, just because the dns access is failing for the roku tv app for some reason.
          # openFirewall = false;
          openFirewall = true;
          user = "root";
          group = "root";
        };

        fortress.storage.btrfs.subvolumes = {
          "media-movies" = {
            mountpoint = lib.mkDefault mediaPaths.movies;
            quota = "2T";
            owner = {
              user = "root";
              group = "root";
              mode = "770";
            };
            dirs = lib.mkDefault (lib.filterAttrs (p: _: lib.hasPrefix "${mediaPaths.movies}/" p) mediaDirs);
          };
          "media-shows" = {
            mountpoint = lib.mkDefault mediaPaths.shows;
            quota = "2T";
            owner = {
              user = "root";
              group = "root";
              mode = "770";
            };
            dirs = lib.mkDefault (lib.filterAttrs (p: _: lib.hasPrefix "${mediaPaths.shows}/" p) mediaDirs);
          };
          "media-music" = {
            mountpoint = lib.mkDefault mediaPaths.music;
            quota = "1T";
            owner = {
              user = "root";
              group = "root";
              mode = "770";
            };
          };
          "jellyfin-metadata" = {
            mountpoint = lib.mkDefault mediaPaths.metadata;
            quota = "50G";
            owner = {
              user = "root";
              group = "root";
              mode = "770";
            };
          };
        };

        systemd.services.jellyfin = {
          after = lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"];
          requires = lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"];
          serviceConfig.TimeoutStopSec = 30;
          serviceConfig.PrivateUsers = lib.mkForce false;
          serviceConfig.NoNewPrivileges = lib.mkForce false;
          # nixpkgs' hardening sets CapabilityBoundingSet= (empty), so uid 0
          # has no CAP_DAC_OVERRIDE and cannot write a /var/lib/jellyfin left
          # behind by an older install (different uid). StateDirectory makes
          # systemd create/chown it, which is the only party that can.
          serviceConfig.StateDirectory = "jellyfin";
          serviceConfig.CacheDirectory = "jellyfin";
          unitConfig.RequiresMountsFor = [
            mediaPaths.movies
            mediaPaths.shows
            mediaPaths.music
            mediaPaths.metadata
          ];
          # Jellyfin's base path (ADR-034) lives in network.xml — no
          # nixpkgs/jellarr knob exists (T0 audit). The file is
          # normalized at start, so pin it before every boot the same
          # way radarr pins config.xml: sed an existing file, else
          # write the minimal document (Jellyfin fills the defaults).
          preStart = lib.mkAfter ''
            cfgDir=${config.services.jellyfin.configDir}
            if [ -f "$cfgDir/network.xml" ]; then
              # Jellyfin writes `<BaseUrl />` when empty and
              # `<BaseUrl>x</BaseUrl>` when set — match both, or the pin
              # silently no-ops and Caddy 404s under the base path.
              ${pkgs.gnused}/bin/sed -i \
                -e "s|<BaseUrl/>|<BaseUrl>${cfg.path}</BaseUrl>|" \
                -e "s|<BaseUrl */>|<BaseUrl>${cfg.path}</BaseUrl>|" \
                -e "s|<BaseUrl>[^<]*</BaseUrl>|<BaseUrl>${cfg.path}</BaseUrl>|" \
                "$cfgDir/network.xml"
            else
              ${pkgs.coreutils}/bin/printf '%s\n' \
                '<NetworkConfiguration>' \
                '  <BaseUrl>${cfg.path}</BaseUrl>' \
                '</NetworkConfiguration>' > "$cfgDir/network.xml"
            fi
          '';
        };
      };
    in
      lib.recursiveUpdate base (lib.optionalAttrs (options.services ? jellarr) {
        systemd.services.jellarr.serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
          StartLimitBurst = 20;
        };

        # The packaged bootstrap stops Jellyfin as soon as jellyfin.db
        # exists — on a fresh boot that is *during* Jellyfin's first
        # startup. Jellyfin defers SIGTERM until its startup tasks
        # finish, so systemd SIGKILLs it and the boot deadlocks. Gate
        # the stop on Jellyfin serving *and* stable: /health returns
        # 200 before the startup tasks run, so require it to hold for
        # 60s before the bootstrap is allowed to stop Jellyfin.
        systemd.services.jellarr-api-key-bootstrap.serviceConfig.ExecStartPre =
          pkgs.writeShellScript "wait-jellyfin-ready" ''
            set -euo pipefail
            for i in $(seq 1 120); do
              if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:8096${cfg.path}/health >/dev/null 2>&1; then
                sleep 60
                exit 0
              fi
              sleep 5
            done
            echo "jellyfin never became ready before api-key bootstrap" >&2
            exit 1
          '';

        services.jellarr = {
          enable = true;
          user = "root";
          group = "root";
          bootstrap = {
            enable = true;
            apiKeyFile = config.sops.secrets.jellarr-api-key.path;
          };
          environmentFile = config.sops.templates."jellarr.env".path;
          config = {
            version = 1;
            base_url = "http://127.0.0.1:8096${cfg.path}";
            system = {};
            startup.completeStartupWizard = true;
            library.virtualFolders = lib.mkDefault [
              {
                name = "Movies";
                collectionType = "movies";
                libraryOptions.pathInfos = [
                  {path = libraryPaths.movies;}
                ];
              }
              {
                name = "TV Shows";
                collectionType = "tvshows";
                libraryOptions.pathInfos = [
                  {path = libraryPaths.shows;}
                ];
              }
              {
                name = "Music";
                collectionType = "music";
                libraryOptions.pathInfos = [
                  {path = mediaPaths.music;}
                ];
              }
            ];
          };
        };

        # Secrets arrive via sops-install-secrets, ordered before
        # fortress.target — no minting oneshot.
        systemd.services.jellarr-api-key-bootstrap = {
          after = ["sops-install-secrets.service"];
          requires = ["sops-install-secrets.service"];
        };

        systemd.services.jellarr = {
          wantedBy = ["fortress.target"];
          after = ["sops-install-secrets.service"];
          requires = ["sops-install-secrets.service"];
        };
      });
  }
