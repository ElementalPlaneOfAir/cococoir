# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/sonarr — TV show management.
#
# 3-option contract (metadata-only service, no bucket).
#
# Media-stack wiring: same pattern as radarr.nix (API key from the
# sealed `sonarr.env` sops template, root identity, media-shows
# downloads/library mounts, PrivateUsers forced off) — see radarr.nix
# + .specify/specs/media-automation-stack/.
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
  name = "sonarr";
  description = "Sonarr TV show management";
  defaultPort = 8989;
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
      config.fortress.media.layout.showsDownloads
      config.fortress.media.layout.showsLibrary
    ];
    # Sonarr keeps its own generated API key once config.xml exists, and
    # <UrlBase> is the app's own knob (ADR-034) — so both are pinned into
    # config.xml, along with the auth posture the Dex gate depends on.
    # See services/_pin-arr.nix.
    pinApiKey = import ./_pin-arr.nix {
      inherit pkgs;
      dataDir = "/var/lib/sonarr/.config/NzbDrone";
      apiKeySecretPath = config.sops.secrets.sonarr-api-key.path;
      urlBase = cfg.path;
    };
  in {
    services.sonarr = {
      enable = true;
      openFirewall = false;
      user = "root";
      group = "root";
      environmentFiles = lib.mkAfter [config.sops.templates."sonarr.env".path];
      settings = {
        server.bindAddress = "127.0.0.1";
        update.automatically = false;
        log.analyticsEnabled = false;
      };
    };

    systemd.services.sonarr = {
      after = lib.mkAfter (lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]);
      requires = lib.mkAfter (lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]);
      unitConfig.RequiresMountsFor = lib.mkAfter mediaDirs;
      serviceConfig = {
        PrivateUsers = lib.mkForce false;
        ExecStartPre = lib.mkAfter pinApiKey;
      };
    };
  };
}
