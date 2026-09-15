# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/sonarr — TV show management.
#
# 3-option contract (metadata-only service, no bucket).
#
# Media-stack wiring: same pattern as radarr.nix (API key env file,
# jellyfin group, media-shows downloads/library mounts, PrivateUsers
# forced off) — see radarr.nix + .specify/specs/media-automation-stack/.
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
  extraConfig = {
    lib,
    config,
    pkgs,
    ...
  }: let
    btrfsStorage = config.fortress.storage.enable && config.fortress.storage.backend == "btrfs";
    dataRoot = config.fortress.storage.dataRoot;
    mediaDirs = [
      "${dataRoot}/media/shows/downloads"
      "${dataRoot}/media/shows/library"
    ];
    pinApiKey = pkgs.writeShellScript "sonarr-pin-api-key" ''
      set -euo pipefail
      key=$(cat /var/lib/fortress-media/sonarr-api-key)
      dir=/var/lib/sonarr/.config/NzbDrone
      install -d -m 0750 -o sonarr -g jellyfin "$dir"
      if [ -f "$dir/config.xml" ]; then
        ${pkgs.gnused}/bin/sed -i "s|<ApiKey>[^<]*</ApiKey>|<ApiKey>$key</ApiKey>|" "$dir/config.xml"
      else
        cat > "$dir/config.xml" <<EOF
  <Config>
    <BindAddress>127.0.0.1</BindAddress>
    <Port>8989</Port>
    <UrlBase></UrlBase>
    <ApiKey>$key</ApiKey>
    <AuthenticationMethod>External</AuthenticationMethod>
    <UpdateMechanism>External</UpdateMechanism>
    <AnalyticsEnabled>False</AnalyticsEnabled>
  </Config>
EOF
      fi
      chown sonarr:jellyfin "$dir/config.xml"
    '';
  in {
    services.sonarr = {
      enable = true;
      openFirewall = false;
      group = "jellyfin";
      environmentFiles = lib.mkAfter ["/var/lib/fortress-media/sonarr.env"];
      settings = {
        server.bindAddress = "127.0.0.1";
        update.automatically = false;
        log.analyticsEnabled = false;
      };
    };

    systemd.services.sonarr = {
      after =
        lib.mkAfter
        (lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]
          ++ ["fortress-media-api-keys.service"]);
      requires =
        lib.mkAfter
        (lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]
          ++ ["fortress-media-api-keys.service"]);
      unitConfig.RequiresMountsFor = lib.mkAfter mediaDirs;
      serviceConfig = {
        PrivateUsers = lib.mkForce false;
        ExecStartPre = lib.mkAfter pinApiKey;
      };
    };
  };
}
