# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/jellyfin-oidc — auto-configure the OIDC
# RBAC plugin bridge between Jellyfin and PocketID.
#
# When both services are enabled and pocketid has a static API
# key, a systemd oneshot:
#   1. Creates an OIDC client in PocketID via its admin API.
#   2. Generates a client secret.
#   3. Injects a Jellyfin API key into Jellyfin's SQLite DB.
#   4. Configures the OIDC RBAC plugin via Jellyfin's REST API
#      (POST /Plugins/{guid}/Configuration).
#
# No raw XML is written — everything goes through the plugin's
# standard configuration API.
#
# Plugin ID: d4e5f6a7-b8c9-0d1e-2f3a-4b5c6d7e8f90 (OIDC RBAC)
{config, lib, pkgs, ...}:
let
  inherit (lib) mkIf getExe;
  jf = config.cococoir.services.jellyfin;
  pi = config.cococoir.services.pocketid;
  hasApiKey = pi.staticApiKeyFile or null != null;
  oidcEnabled = jf.enable && pi.enable && hasApiKey;
  curl = getExe pkgs.curl;
  jq = getExe pkgs.jq;
  piPort = toString pi.port;
  pluginGuid = "d4e5f6a7b8c90d1e2f3a4b5c6d7e8f90";
  jfApiKey = pkgs.runCommand "cococoir-jellyfin-oidc-api-key" {
    buildInputs = [pkgs.openssl];
  } ''
    mkdir -p $out
    openssl rand -hex 32 > $out/key
  '';
in
mkIf oidcEnabled {
  systemd.services.cococoir-jellyfin-oidc = {
    description = "Cococoir Jellyfin-PocketID OIDC bridge";
    wantedBy = ["multi-user.target"];
    after = ["pocketid.service" "jellyfin.service" "network.target"];
    requires = ["pocketid.service"];
    path = [pkgs.sqlite pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cococoir-jellyfin-oidc" ''
        set -euo pipefail

        PI_DIRECT="http://127.0.0.1:${piPort}"
        PI_URL="https://${pi.domain}"
        CALLBACK="https://${jf.domain}/sso/OIDC/Callback/pocketid"
        API_KEY_FILE="${pi.staticApiKeyFile}"
        CLIENT_ID="jellyfin"
        JF_DB="/var/lib/jellyfin/data/jellyfin.db"
        JF_API_KEY_FILE="${jfApiKey}/key"
        JF_BASE="http://127.0.0.1:8096"
        PLUGIN_CONFIG="$JF_BASE/Plugins/${pluginGuid}/Configuration"

        CURL="${curl} -sf --max-time 10 --connect-timeout 5"
        API_KEY=$(cat "$API_KEY_FILE")
        AUTH_HDR="X-API-Key: $API_KEY"

        echo "Waiting for PocketID at $PI_DIRECT..."
        for i in $(seq 1 30); do
          if $CURL -H "$AUTH_HDR" -o /dev/null \
            "$PI_DIRECT/api/oidc/clients"; then
            break
          fi
          sleep 2
        done

        if $CURL -H "$AUTH_HDR" \
          "$PI_DIRECT/api/oidc/clients/$CLIENT_ID" > /dev/null 2>&1; then
          echo "OIDC client $CLIENT_ID already exists"
        else
          echo "Creating OIDC client $CLIENT_ID..."
          BODY=$(${jq} -n \
            --arg id "$CLIENT_ID" \
            --arg name "Jellyfin" \
            --arg cb "$CALLBACK" \
            '{id: $id, name: $name, callbackURLs: [$cb], isPublic: false}')
          $CURL -X POST \
            -H "$AUTH_HDR" \
            -H "Content-Type: application/json" \
            -d "$BODY" \
            "$PI_DIRECT/api/oidc/clients"
        fi

        echo "Generating client secret..."
        SECRET_RESP=$($CURL -X POST \
          -H "$AUTH_HDR" \
          "$PI_DIRECT/api/oidc/clients/$CLIENT_ID/secret")
        OIDC_SECRET=$(echo "$SECRET_RESP" | ${jq} -r '.secret')
        if [ -z "$OIDC_SECRET" ] || [ "$OIDC_SECRET" = "null" ]; then
          echo "Failed to get client secret" >&2
          exit 1
        fi

        echo "Waiting for Jellyfin at $JF_BASE..."
        for i in $(seq 1 60); do
          if $CURL -o /dev/null "$JF_BASE/System/Info/Public"; then
            break
          fi
          sleep 2
        done

        echo "Injecting Jellyfin API key..."
        JF_KEY=$(cat "$JF_API_KEY_FILE" | tr -d '[:space:]')
        until [ -e "$JF_DB" ]; do sleep 1; done
        systemctl stop jellyfin
        sleep 5
        sqlite3 "$JF_DB" <<SQL
        BEGIN IMMEDIATE;
        INSERT INTO ApiKeys (AccessToken, Name, DateCreated, DateLastActivity)
        SELECT '$JF_KEY', 'cococoir-jellyfin-oidc', datetime('now'), datetime('now')
        WHERE NOT EXISTS (SELECT 1 FROM ApiKeys WHERE Name='cococoir-jellyfin-oidc');
        COMMIT;
        SQL
        systemctl start jellyfin

        echo "Waiting for Jellyfin to restart..."
        for i in $(seq 1 30); do
          if $CURL -o /dev/null "$JF_BASE/System/Info/Public"; then
            break
          fi
          sleep 2
        done

        echo "Configuring OIDC RBAC plugin..."
        CONFIG=$(${jq} -n \
          --arg authority "$PI_URL" \
          --arg clientId "$CLIENT_ID" \
          --arg clientSecret "$OIDC_SECRET" \
          '{
            Providers: [{
              ProviderId: "pocketid",
              DisplayName: "PocketID",
              Authority: $authority,
              ClientId: $clientId,
              ClientSecret: $clientSecret,
              Scopes: "openid profile email",
              RoleClaim: "groups",
              UsernameClaim: "preferred_username",
              DisplayNameClaim: "name",
              PictureClaim: "picture",
              SyncProfileImage: true,
              Enabled: true,
              ButtonColor: "#4285F4",
              ButtonIcon: "",
              AdditionalParameters: "",
              ServerBaseUrl: ""
            }],
            RoleMappings: [],
            DefaultProvider: "pocketid",
            AutoCreateUsers: true,
            DefaultRoleName: ""
          }')
        $CURL -X POST \
          -H "X-Emby-Token: $JF_KEY" \
          -H "Content-Type: application/json" \
          -d "$CONFIG" \
          "$PLUGIN_CONFIG"

        echo "OIDC bridge configured"
      '';
    };
  };
}
