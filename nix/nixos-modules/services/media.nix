# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/media — shared machinery for the media automation
# stack (radarr/sonarr/qbittorrent/seerr).
#
# The *toggle* (fortress.services.media.enable) lives here too (T7).
#
# fortress-media-api-keys (jellarr pattern, jellyfin.nix:196): one
# idempotent oneshot generates each *arr API key once and writes it
# into an env file the *arr systemd service consumes via
# `environmentFiles` (RADARR__SERVER__APIKEY=...). The Seerr bootstrap
# password (for the seerr-bootstrap Jellyfin admin user) is generated
# once too. No key ever enters the Nix store.
#
# fortress-media-apply: idempotent curl+jq handshake at boot —
#   1. qbittorrent categories (per-category save paths; qbt persists
#      them in categories.json, which is not conf-declarable), so a
#      torrent can never land outside the media subvolumes even
#      before the arrs configure their clients.
#   2. radarr/sonarr: download client (qBittorrent, category movies/tv),
#      root folder (<subvol>/library), hardlink import config.
#   3. seerr: Seerr's only first-boot admin path is Jellyfin sign-in
#      (local login has no admin-creation route). We bootstrap a
#      dedicated Jellyfin admin user (seerr-bootstrap) with the
#      generated password, sign Seerr in through it — which auto-creates
#      the Seerr admin AND auto-configures the Jellyfin connection —
#      then wire both *arrs in with their real profile + root folder.
#      A 401/403 means the customer owns Seerr now — log loudly and
#      skip, never lock the customer out.
#
# Auto-activation: gated on the *arrs being enabled, never on a
# separate integration toggle. Tripwire: vmtest-wiring asserts the
# oneshots render when the media stack is on.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  btrfsStorage = config.fortress.storage.enable && config.fortress.storage.backend == "btrfs";
  dataRoot = config.fortress.storage.dataRoot;
  mediaRoot = "/var/lib/fortress-media";
  keyFor = name: "${mediaRoot}/${name}-api-key";
  envFor = name: "${mediaRoot}/${name}.env";
  keyFileScript = pkgs.writeShellScript "fortress-media-api-keys" ''
    set -euo pipefail
    umask 077
    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g jellyfin ${mediaRoot}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: envVar: ''
      if [ ! -f ${keyFor name} ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${keyFor name}
      fi
      ${pkgs.coreutils}/bin/printf '${envVar}=%s\n' "$(${pkgs.coreutils}/bin/cat ${keyFor name})" > ${envFor name}
      ${pkgs.coreutils}/bin/chmod 0640 ${envFor name}
    '') {radarr = "RADARR__SERVER__APIKEY"; sonarr = "SONARR__SERVER__APIKEY";})}
    if [ ! -f ${mediaRoot}/seerr-admin-password ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${mediaRoot}/seerr-admin-password
    fi
    ${pkgs.coreutils}/bin/chown root:jellyfin \
      ${keyFor "radarr"} ${keyFor "sonarr"} ${mediaRoot}/seerr-admin-password \
      ${envFor "radarr"} ${envFor "sonarr"}
    ${pkgs.coreutils}/bin/chmod 0640 \
      ${keyFor "radarr"} ${keyFor "sonarr"} ${mediaRoot}/seerr-admin-password \
      ${envFor "radarr"} ${envFor "sonarr"}
  '';

  qbtBase = "http://127.0.0.1:8080";
  radarrBase = "http://127.0.0.1:7878";
  sonarrBase = "http://127.0.0.1:8989";
  seerrBase = "http://127.0.0.1:5055";
  jellyfinBase = "http://127.0.0.1:8096";
  seerrBootstrapUser = "seerr-bootstrap";
  moviesRoot = "${dataRoot}/media/movies/library";
  showsRoot = "${dataRoot}/media/shows/library";
  moviesDownloads = "${dataRoot}/media/movies/downloads";
  showsDownloads = "${dataRoot}/media/shows/downloads";

  applyScript = pkgs.writeShellScript "fortress-media-apply" ''
    set -euo pipefail
    umask 077

    radarr_key=$(cat ${mediaRoot}/radarr-api-key)
    sonarr_key=$(cat ${mediaRoot}/sonarr-api-key)
    jellyfin_key=$(cat /var/lib/jellarr/api-key)
    seerr_password=$(cat ${mediaRoot}/seerr-admin-password)
    # Jellyfin 12 requires the Authorization header; X-Emby-Token
    # returns 401 (same break as upstream jellarr, fixed there by
    # PR #79).
    jellyfin_auth="MediaBrowser Token=\"$jellyfin_key\", Client=\"fortress-media-apply\", Device=\"fortress-media-apply\", DeviceId=\"fortress-media-apply\", Version=\"0.1.0\""
    cookie_jar=$(mktemp)
    trap '${pkgs.coreutils}/bin/rm -f "$cookie_jar"' EXIT

    wait_ready() {
      local label=$1 base=$2 key=$3 health_path=$4 header=$5 i
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        if ${pkgs.curl}/bin/curl -sf -H "''${header}: ''${key}" "''${base}''${health_path}" >/dev/null 2>&1; then
          return 0
        fi
        echo "[fortress-media-apply] ''${label} not ready (attempt ''${i}/60)" >&2
        ${pkgs.coreutils}/bin/sleep 5
      done
      echo "[fortress-media-apply] ''${label} never became ready" >&2
      exit 1
    }

    # jellarr's bootstrap restarts Jellyfin several times while Jellyfin
    # finishes its first-boot load, so System/Info can be briefly 200
    # between restarts. Wait until jellarr has *finished* (oneshot unit
    # gone inactive) before wiring anything against Jellyfin.
    wait_jellarr_done() {
      local i state result
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        state=$(${pkgs.systemd}/bin/systemctl show jellarr.service -p ActiveState --value)
        result=$(${pkgs.systemd}/bin/systemctl show jellarr.service -p Result --value)
        if [ "$state" = "inactive" ] && [ "$result" = "success" ]; then
          return 0
        fi
        echo "[fortress-media-apply] jellarr not finished (''${state}, result ''${result}, attempt ''${i}/60)" >&2
        ${pkgs.coreutils}/bin/sleep 5
      done
      echo "[fortress-media-apply] jellarr never finished applying" >&2
      exit 1
    }

    ensure_root_folder() {
      local base=$1 key=$2 root=$3 listing
      listing=$(${pkgs.curl}/bin/curl -sf -H "X-Api-Key: ''${key}" "''${base}/api/v3/rootfolder")
      if ! ${pkgs.jq}/bin/jq -e --arg p "''${root}" 'map(.path) | index($p) != null' <<<"''${listing}" >/dev/null; then
        ${pkgs.curl}/bin/curl -sf -X POST -H "X-Api-Key: ''${key}" -H 'Content-Type: application/json' \
          -d "{\"path\": \"''${root}\"}" "''${base}/api/v3/rootfolder" >/dev/null
      fi
    }

    ensure_download_client() {
      local base=$1 key=$2 category=$3 listing
      listing=$(${pkgs.curl}/bin/curl -sf -H "X-Api-Key: ''${key}" "''${base}/api/v3/downloadclient")
      if ! ${pkgs.jq}/bin/jq -e 'map(select(.name == "qBittorrent")) | length > 0' <<<"''${listing}" >/dev/null; then
        ${pkgs.jq}/bin/jq -n --arg category "''${category}" \
          '{name: "qBittorrent", implementation: "QBittorrent", configContract: "QbittorrentSettings",
            protocol: "torrent", enable: true, priority: 1,
            removeCompletedDownloads: true, removeFailedDownloads: true, tags: [],
            fields: [
              {name: "host", value: "127.0.0.1"},
              {name: "port", value: 8080},
              {name: "useSsl", value: false},
              {name: "baseUrl", value: ""},
              {name: "category", value: $category}
            ]}' \
          | ${pkgs.curl}/bin/curl -sf -X POST -H "X-Api-Key: ''${key}" -H 'Content-Type: application/json' \
              -d @- "''${base}/api/v3/downloadclient" >/dev/null
      fi
    }

    ensure_hardlinks() {
      local base=$1 key=$2 config
      config=$(${pkgs.curl}/bin/curl -sf -H "X-Api-Key: ''${key}" "''${base}/api/v3/config/mediamanagement")
      if [ "$(${pkgs.jq}/bin/jq -r '.useHardlinksInsteadOfCopy // false' <<<"''${config}")" != "true" ]; then
        ${pkgs.jq}/bin/jq '.useHardlinksInsteadOfCopy = true' <<<"''${config}" \
          | ${pkgs.curl}/bin/curl -sf -X PUT -H "X-Api-Key: ''${key}" -H 'Content-Type: application/json' \
              -d @- "''${base}/api/v3/config/mediamanagement" >/dev/null
      fi
    }

    ensure_qbt_category() {
      local name=$1 save_path=$2 categories
      categories=$(${pkgs.curl}/bin/curl -sf "${qbtBase}/api/v2/torrents/categories")
      if ! ${pkgs.jq}/bin/jq -e --arg n "''${name}" 'has($n)' <<<"''${categories}" >/dev/null; then
        ${pkgs.curl}/bin/curl -sf -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
          --data-urlencode "category=''${name}" \
          --data-urlencode "savePath=''${save_path}" \
          "${qbtBase}/api/v2/torrents/createCategory" >/dev/null
      fi
    }

    register_seerr_service() {
      local kind=$1 label=$2 port=$3 arr_base=$4 arr_key=$5 root=$6 extra=$7
      local list profile payload
      list=$(${pkgs.curl}/bin/curl -sf -b "''${cookie_jar}" "${seerrBase}/api/v1/settings/''${kind}")
      if ${pkgs.jq}/bin/jq -e --argjson port "''${port}" \
          '[.[] | select(.hostname == "127.0.0.1" and .port == $port)] | length > 0' \
          <<<"''${list}" >/dev/null; then
        return 0
      fi
      profile=$(${pkgs.curl}/bin/curl -sf -H "X-Api-Key: ''${arr_key}" "''${arr_base}/api/v3/qualityprofile" \
        | ${pkgs.jq}/bin/jq '.[0]')
      payload=$(${pkgs.jq}/bin/jq -n \
        --arg label "''${label}" --arg apiKey "''${arr_key}" --arg root "''${root}" \
        --argjson port "''${port}" --argjson profile "''${profile}" --argjson extra "''${extra}" \
        '{name: $label, hostname: "127.0.0.1", port: $port, apiKey: $apiKey,
          useSsl: false, baseUrl: "", activeProfileId: $profile.id,
          activeProfileName: $profile.name, activeDirectory: $root,
          is4k: false, minimumAvailability: "Released", isDefault: true,
          syncEnabled: true, preventSearch: false, externalUrl: ""} + $extra')
      ${pkgs.curl}/bin/curl -sf -b "''${cookie_jar}" -H 'Content-Type: application/json' \
        -d "''${payload}" "${seerrBase}/api/v1/settings/''${kind}" >/dev/null
    }

    ensure_jellyfin_bootstrap_user() {
      local list user_id
      list=$(${pkgs.curl}/bin/curl -sf -H "Authorization: $jellyfin_auth" \
        "${jellyfinBase}/Users")
      if [ "$(${pkgs.jq}/bin/jq -r 'length' <<<"''${list}")" = "0" ]; then
        ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: $jellyfin_auth" \
          -H 'Content-Type: application/json' \
          -d "{\"Name\": \"${seerrBootstrapUser}\"}" \
          "${jellyfinBase}/Users/New" >/dev/null
      fi
      user_id=$(${pkgs.jq}/bin/jq -r \
        --arg n "${seerrBootstrapUser}" '.[] | select(.Name == $n) | .Id' <<<"''${list}")
      if [ -z "$user_id" ]; then
        list=$(${pkgs.curl}/bin/curl -sf -H "Authorization: $jellyfin_auth" "${jellyfinBase}/Users")
        user_id=$(${pkgs.jq}/bin/jq -r \
          --arg n "${seerrBootstrapUser}" '.[] | select(.Name == $n) | .Id' <<<"''${list}")
      fi
      if [ -z "$user_id" ]; then
        echo "[fortress-media-apply] could not find or create Jellyfin user ${seerrBootstrapUser}" >&2
        exit 1
      fi
      ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: $jellyfin_auth" \
        -H 'Content-Type: application/json' \
        -d "{\"Id\": \"''${user_id}\", \"NewPw\": \"$seerr_password\"}" \
        "${jellyfinBase}/Users/''${user_id}/Password" >/dev/null
      policy=$(${pkgs.curl}/bin/curl -sf -H "Authorization: $jellyfin_auth" \
        "${jellyfinBase}/Users/''${user_id}" | ${pkgs.jq}/bin/jq '.Policy | .IsAdministrator = true')
      ${pkgs.curl}/bin/curl -sf -X POST -H "Authorization: $jellyfin_auth" \
        -H 'Content-Type: application/json' -d "''${policy}" \
        "${jellyfinBase}/Users/''${user_id}/Policy" >/dev/null
    }

    ${lib.optionalString config.services.qbittorrent.enable ''
    wait_ready qbittorrent ${qbtBase} "" /api/v2/app/version X-Api-Key
    ensure_qbt_category movies ${moviesDownloads}
    ensure_qbt_category tv ${showsDownloads}
    echo "[fortress-media-apply] qbt categories ready"
    ''}

    ${lib.optionalString config.services.radarr.enable ''
    wait_ready radarr ${radarrBase} "$radarr_key" /api/v3/health X-Api-Key
    ensure_root_folder ${radarrBase} "$radarr_key" ${moviesRoot}
    ensure_download_client ${radarrBase} "$radarr_key" movies
    ensure_hardlinks ${radarrBase} "$radarr_key"
    ''}

    ${lib.optionalString config.services.sonarr.enable ''
    wait_ready sonarr ${sonarrBase} "$sonarr_key" /api/v3/health X-Api-Key
    ensure_root_folder ${sonarrBase} "$sonarr_key" ${showsRoot}
    ensure_download_client ${sonarrBase} "$sonarr_key" tv
    ensure_hardlinks ${sonarrBase} "$sonarr_key"
    ''}

    ${lib.optionalString config.services.seerr.enable ''
    wait_ready seerr ${seerrBase} "" /api/v1/status X-Api-Key
    wait_jellarr_done
    wait_ready jellyfin ${jellyfinBase} "$jellyfin_auth" /System/Info Authorization
    ensure_jellyfin_bootstrap_user
    # Seerr's Jellyfin login accepts hostname only on a fresh DB (it
    # 500s with "already configured" once settings.jellyfin.ip is set).
    # Try WITH hostname first (first-boot bootstrap), then without it
    # (steady-state re-auth) when the "already configured" guard fires.
    login_with_host="{\"username\": \"${seerrBootstrapUser}\", \"password\": \"$seerr_password\", \"hostname\": \"127.0.0.1\", \"port\": 8096, \"useSsl\": false, \"urlBase\": \"\", \"serverType\": 2}"
    login_without_host="{\"username\": \"${seerrBootstrapUser}\", \"password\": \"$seerr_password\", \"useSsl\": false, \"serverType\": 2}"
    login_code=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -c "$cookie_jar" \
      -d "$login_with_host" "${seerrBase}/api/v1/auth/jellyfin") || login_code=000
    if [ "$login_code" = "500" ]; then
      login_code=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -c "$cookie_jar" \
        -d "$login_without_host" "${seerrBase}/api/v1/auth/jellyfin") || login_code=000
    fi
    case "$login_code" in
      401|403)
        echo "[fortress-media-apply] seerr bootstrap login refused (HTTP $login_code); skipping seerr wiring" >&2
        exit 0
        ;;
      200) ;;
      *)
        echo "[fortress-media-apply] seerr bootstrap login failed (HTTP $login_code)" >&2
        exit 1
        ;;
    esac

    jellyfin_libraries=$(${pkgs.curl}/bin/curl -sf -b "$cookie_jar" "${seerrBase}/api/v1/settings/jellyfin/library")
    ${pkgs.jq}/bin/jq -e 'type == "array"' <<<"$jellyfin_libraries" >/dev/null

    ${lib.optionalString config.services.radarr.enable ''
    register_seerr_service radarr "Radarr Main" 7878 ${radarrBase} "$radarr_key" ${moviesRoot} '{}'
    ''}
    ${lib.optionalString config.services.sonarr.enable ''
    register_seerr_service sonarr "Sonarr Main" 8989 ${sonarrBase} "$sonarr_key" ${showsRoot} '{"enableSeasonFolders": false}'
    ''}
    echo "[fortress-media-apply] seerr wired to jellyfin + radarr + sonarr"
    ''}

    echo "[fortress-media-apply] applied"
  '';
in
{
  options.fortress.services.media = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable the media automation stack — one toggle
        brings up radarr, sonarr, qbittorrent and seerr, fully wired
        (download client, root folders, hardlink imports, request
        routing). Jellyfin must be enabled as well (the *arrs
        require it). After first boot the customer adds at least
        one indexer in radarr/sonarr's UIs — the one deliberate
        manual step; without an indexer nothing downloads.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.fortress.services.media.enable {
      fortress.services.radarr.enable = lib.mkDefault true;
      fortress.services.sonarr.enable = lib.mkDefault true;
      fortress.services.qbittorrent.enable = lib.mkDefault true;
      fortress.services.seerr.enable = lib.mkDefault true;
    })

    (lib.mkIf (config.services.radarr.enable || config.services.sonarr.enable) {
      systemd.services.fortress-media-api-keys = {
        description = "Generate *arr API keys (idempotent)";
        wantedBy = ["multi-user.target"];
        before = ["radarr.service" "sonarr.service"];
        after = ["systemd-tmpfiles-setup.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = keyFileScript;
        };
        path = [pkgs.openssl];
      };

      systemd.services.fortress-media-apply = {
        description = "Apply media stack wiring (qbittorrent, radarr, sonarr, seerr)";
        wantedBy = ["multi-user.target"];
        after =
          ["fortress-media-api-keys.service"]
          ++ lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"]
          ++ lib.optional config.services.radarr.enable "radarr.service"
          ++ lib.optional config.services.sonarr.enable "sonarr.service"
          ++ lib.optional config.services.qbittorrent.enable "qbittorrent.service"
          ++ lib.optionals config.services.seerr.enable
          (["seerr.service" "jellyfin.service"]
            ++ lib.optionals (options.services ? jellarr) ["jellarr.service"]);
        requires =
          ["fortress-media-api-keys.service"]
          ++ lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 15;
          StartLimitBurst = 10;
          ExecStart = applyScript;
        };
        path = [pkgs.curl pkgs.jq pkgs.systemd];
      };
    })
  ];
}
