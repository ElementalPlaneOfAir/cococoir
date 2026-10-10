# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/radarr — Movie management.
#
# 3-option contract (metadata-only service, no bucket):
#   enable  — opt-in toggle
#   domain  — external FQDN for the Caddy vhost
#   public  — true → Caddy reverse-proxies; false → 403
#
# Media-stack wiring (see .specify/specs/media-automation-stack/):
#   - API key: RADARR__SERVER__APIKEY env var (environmentFiles ← the
#     sealed `radarr.env` sops template). Env vars override config.xml;
#     the value is sealed ciphertext in the store (secrets.nix).
#   - Runs as root (ADR-036): imports hardlink from the media-movies
#     `downloads/` dir into `library/` (both 0770), so it needs write
#     access to the whole media tree.
#   - PrivateUsers forced off (the nixpkgs unit's default revokes
#     access to those subvolumes; tripwired in vmtest-wiring).
#   - Orders after the btrfs subvolume service; secrets arrive via
#     sops-install-secrets, ordered before fortress.target.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkFortressService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkFortressService {
  name = "radarr";
  description = "Radarr movie management";
  defaultPort = 7878;
  defaultHealthPath = "/ping";
  requires = ["jellyfin"];
  accessGroup = "arr";
  extraConfig = {
    cfg,
    lib,
    config,
    pkgs,
    ...
  }: let
    btrfsStorage = config.fortress.storage.enable && config.fortress.storage.backend == "btrfs";
    dataRoot = config.fortress.storage.dataRoot;
    mediaDirs = [
      config.fortress.media.layout.moviesDownloads
      config.fortress.media.layout.moviesLibrary
    ];
    # Radarr ignores the RADARR__SERVER__APIKEY env override once
    # config.xml exists (it keeps its own generated key), and <UrlBase> is
    # the app's own knob (ADR-034) — so both are pinned straight into
    # config.xml, along with the auth posture the Dex gate depends on.
    # See services/_pin-arr.nix.
    pinApiKey = import ./_pin-arr.nix {
      inherit pkgs;
      dataDir = "/var/lib/radarr/.config/Radarr";
      apiKeySecretPath = config.sops.secrets.radarr-api-key.path;
      urlBase = cfg.path;
    };
  in {
    services.radarr = {
      enable = true;
      openFirewall = false;
      user = "root";
      group = "root";
      environmentFiles = lib.mkAfter [config.sops.templates."radarr.env".path];
      settings = {
        server.bindAddress = "127.0.0.1";
        update.automatically = false;
        log.analyticsEnabled = false;
      };
    };

    systemd.services.radarr = {
      after = lib.mkAfter (lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]);
      requires = lib.mkAfter (lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]);
      unitConfig.RequiresMountsFor = lib.mkAfter mediaDirs;
      serviceConfig = {
        PrivateUsers = lib.mkForce false;
        NoNewPrivileges = lib.mkForce false;
        # systemd (pid 1) creates /var/lib/radarr with the unit's own uid,
        # so the pre-start can write it without CAP_DAC_OVERRIDE.
        StateDirectory = "radarr";
        ExecStartPre = lib.mkAfter pinApiKey;
      };
    };
  };
}
