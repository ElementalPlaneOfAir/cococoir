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
#   - API key: RADARR__SERVER__APIKEY env var (environmentFiles ←
#     fortress-media-api-keys oneshot; jellarr pattern). Env vars
#     override config.xml; the key never enters the Nix store.
#   - Runs in the `jellyfin` group: imports hardlink from the
#     media-movies `downloads/` dir into `library/` (both 0770
#     root-shared).
#   - PrivateUsers forced off (supplementary-group mapping breaks
#     under the nixpkgs unit's default; tripwired in vmtest-wiring).
#   - Orders after the btrfs subvolume service + the key oneshot.
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
  extraConfig = {
    lib,
    config,
    pkgs,
    ...
  }: let
    btrfsStorage = config.fortress.storage.enable && config.fortress.storage.backend == "btrfs";
    dataRoot = config.fortress.storage.dataRoot;
    mediaDirs = [
      "${dataRoot}/media/movies/downloads"
      "${dataRoot}/media/movies/library"
    ];
    # Radarr ignores the RADARR__SERVER__APIKEY env override once
    # config.xml exists (it keeps its own generated key), so the key is
    # pinned straight into config.xml. The key file is 0640 root:jellyfin —
    # ExecStartPre runs as radarr (jellyfin group).
    pinApiKey = pkgs.writeShellScript "radarr-pin-api-key" ''
      set -euo pipefail
      key=$(cat /var/lib/fortress-media/radarr-api-key)
      dir=/var/lib/radarr/.config/Radarr
      install -d -m 0750 -o radarr -g jellyfin "$dir"
      if [ -f "$dir/config.xml" ]; then
        ${pkgs.gnused}/bin/sed -i "s|<ApiKey>[^<]*</ApiKey>|<ApiKey>$key</ApiKey>|" "$dir/config.xml"
      else
        cat > "$dir/config.xml" <<EOF
  <Config>
    <BindAddress>127.0.0.1</BindAddress>
    <Port>7878</Port>
    <UrlBase></UrlBase>
    <ApiKey>$key</ApiKey>
    <AuthenticationMethod>External</AuthenticationMethod>
    <UpdateMechanism>External</UpdateMechanism>
    <AnalyticsEnabled>False</AnalyticsEnabled>
  </Config>
EOF
      fi
      chown radarr:jellyfin "$dir/config.xml"
    '';
  in {
    services.radarr = {
      enable = true;
      openFirewall = false;
      group = "jellyfin";
      environmentFiles = lib.mkAfter ["/var/lib/fortress-media/radarr.env"];
      settings = {
        server.bindAddress = "127.0.0.1";
        update.automatically = false;
        log.analyticsEnabled = false;
      };
    };

    systemd.services.radarr = {
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
