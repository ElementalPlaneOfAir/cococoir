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
      "${dataRoot}/media/movies/downloads"
      "${dataRoot}/media/movies/library"
    ];
    # Radarr ignores the RADARR__SERVER__APIKEY env override once
    # config.xml exists (it keeps its own generated key), so the key is
    # pinned straight into config.xml — and so is the base path
    # (ADR-034): <UrlBase> is the app's own knob and nothing else
    # (nixpkgs, seerr) can set it declaratively. The key file is 0640
    # root:jellyfin — ExecStartPre runs as radarr (jellyfin group).
    pinApiKey = pkgs.writeShellScript "radarr-pin-api-key" ''
      set -euo pipefail
      key=$(cat ${config.sops.secrets.radarr-api-key.path})
      dir=/var/lib/radarr/.config/Radarr
      install -d -m 0750 -o root -g root "$dir"
      if [ -f "$dir/config.xml" ]; then
        ${pkgs.gnused}/bin/sed -i \
          -e "s|<ApiKey>[^<]*</ApiKey>|<ApiKey>$key</ApiKey>|" \
          -e "s|<UrlBase>[^<]*</UrlBase>|<UrlBase>${cfg.path}</UrlBase>|" \
          "$dir/config.xml"
      else
        cat > "$dir/config.xml" <<EOF
  <Config>
    <BindAddress>127.0.0.1</BindAddress>
    <Port>7878</Port>
    <UrlBase>${cfg.path}</UrlBase>
    <ApiKey>$key</ApiKey>
    <AuthenticationMethod>External</AuthenticationMethod>
    <UpdateMechanism>External</UpdateMechanism>
    <AnalyticsEnabled>False</AnalyticsEnabled>
  </Config>
EOF
      fi
      chown root:root "$dir/config.xml"
    '';
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
        ExecStartPre = lib.mkAfter pinApiKey;
      };
    };
  };
}
