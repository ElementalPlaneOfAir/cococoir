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
  jellarrApiKey = pkgs.runCommand "jellarr-api-key" {
    buildInputs = [pkgs.openssl];
  } ''
    mkdir -p $out
    openssl rand -hex 32 > $out/key
  '';
  jellarrEnvFile = pkgs.writeText "jellarr-env" ''
    JELLARR_API_KEY=${builtins.readFile "${jellarrApiKey}/key"}
  '';
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
    environment.etc."cococoir/jellarr-api-key" = {
      text = builtins.readFile "${jellarrApiKey}/key";
      mode = "0400";
      user = "jellyfin";
      group = "jellyfin";
    };
    services.jellarr = {
      enable = true;
      user = "jellyfin";
      group = "jellyfin";
      bootstrap = {
        enable = true;
        apiKeyFile = "${jellarrApiKey}/key";
      };
      environmentFile = "${jellarrEnvFile}";
      config = {
        version = 1;
        base_url = "http://127.0.0.1:8096";
        system = {};
        startup.completeStartupWizard = true;
        library.virtualFolders = [
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
  });
}
