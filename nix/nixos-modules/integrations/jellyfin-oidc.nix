# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/jellyfin-oidc — auto-configure the OIDC
# RBAC plugin bridge between Jellyfin and PocketID.
#
# When both services are enabled and pocketid has a static API
# key, this module:
#   1. Installs the OIDC RBAC plugin DLLs via a systemd preStart
#      on jellyfin.service.
#   2. Declares the OIDC plugin configuration and SSO login
#      button branding via jellarr's config (with a @OIDC_SECRET@
#      placeholder for the one runtime value).
#   3. Runs a oneshot that provisions the OIDC client in PocketID
#      and persists the client secret to /var/lib/cococoir/.
#   4. Appends a preStart to jellarr.service that substitutes
#      @OIDC_SECRET@ with the persisted secret before jellarr runs.
#
# All Jellyfin REST API interaction is owned by jellarr. This
# module only handles the one thing jellarr can't: PocketID-side
# client provisioning.
#
# Plugin ID: d4e5f6a7-b8c9-0d1e-2f3a-4b5c6d7e8f90 (OIDC RBAC)
{config, lib, pkgs, options, ...}:
let
  inherit (lib) mkIf getExe;
  jf = config.cococoir.services.jellyfin;
  pi = config.cococoir.services.pocketid;
  hasApiKey = pi.staticApiKeyFile or null != null;
  oidcEnabled = jf.enable && pi.enable && hasApiKey;
  curl = getExe pkgs.curl;
  jq = getExe pkgs.jq;
  piPort = toString pi.port;

  oidcPlugin = pkgs.stdenv.mkDerivation {
    pname = "jellyfin-plugin-oidc-rbac";
    version = "1.0.8";
    src = pkgs.fetchzip {
      url = "https://github.com/Ezeqielle/jellyfin-plugin-oidc/releases/download/v1.0.8/oidc-rbac.zip";
      hash = "sha256-qZ50uaVVQ0A4BFEVuPqldT3nN30P4gPZTDheW1up52I=";
      stripRoot = false;
    };
    installPhase = ''
      mkdir -p $out
      cp *.dll $out/
    '';
  };

  secretFile = "/var/lib/cococoir/jellyfin-oidc-secret";
in
mkIf oidcEnabled (lib.mkMerge [
  {
    systemd.services.jellyfin.preStart = lib.mkBefore ''
      mkdir -p /var/lib/jellyfin/plugins/"OIDC RBAC"
      rm -f /var/lib/jellyfin/plugins/"OIDC RBAC"/*.dll
      ln -sf ${oidcPlugin}/* /var/lib/jellyfin/plugins/"OIDC RBAC"/
      chmod -R 770 /var/lib/jellyfin/plugins/"OIDC RBAC"
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/cococoir 0755 root root -"
    ];

    systemd.services.cococoir-jellyfin-oidc = {
      description = "Cococoir Jellyfin-PocketID OIDC client provisioning";
      wantedBy = ["multi-user.target"];
      after = ["pocketid.service" "network.target" "cococoir-pocketid-provision.service"];
      requires = ["pocketid.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cococoir-jellyfin-oidc" ''
          set -euo pipefail

          PI_DIRECT="http://127.0.0.1:${piPort}"
          API_KEY_FILE="${pi.staticApiKeyFile}"
          CLIENT_ID="jellyfin"
          SECRET_FILE="${secretFile}"

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
            CALLBACK="https://${jf.domain}/sso/OIDC/Callback/pocketid"
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

          if [ ! -f "$SECRET_FILE" ]; then
            echo "Generating client secret..."
            SECRET_RESP=$($CURL -X POST \
              -H "$AUTH_HDR" \
              "$PI_DIRECT/api/oidc/clients/$CLIENT_ID/secret")
            OIDC_SECRET=$(echo "$SECRET_RESP" | ${jq} -r '.secret')
            if [ -z "$OIDC_SECRET" ] || [ "$OIDC_SECRET" = "null" ]; then
              echo "Failed to get client secret" >&2
              exit 1
            fi
            echo "$OIDC_SECRET" > "$SECRET_FILE"
            chmod 0400 "$SECRET_FILE"
            chown jellyfin:jellyfin "$SECRET_FILE"
          else
            echo "Client secret already exists at $SECRET_FILE"
          fi

          echo "Ensuring jellyfin-users group..."
          JF_GROUP_UUID=$($CURL "$PI_DIRECT/api/user-groups?search=jellyfin-users" \
            | ${jq} -r '.data[] | select(.name == "jellyfin-users") | .id')
          if [ -z "$JF_GROUP_UUID" ]; then
            echo "Creating jellyfin-users group..."
            JF_GROUP_UUID=$($CURL -X POST \
              -H "$AUTH_HDR" \
              -H "Content-Type: application/json" \
              -d '{"name":"jellyfin-users","friendlyName":"Jellyfin Users"}' \
              "$PI_DIRECT/api/user-groups" | ${jq} -r '.id')
          fi
          echo "jellyfin-users -> $JF_GROUP_UUID"

          echo "Setting allowed user groups on OIDC client $CLIENT_ID..."
          ADMIN_GROUP_UUID=$($CURL "$PI_DIRECT/api/user-groups?search=cococoir-admins" \
            | ${jq} -r '.data[] | select(.name == "cococoir-admins") | .id')
          GROUP_LIST=$(echo -n "[\"$JF_GROUP_UUID\"]")
          if [ -n "$ADMIN_GROUP_UUID" ]; then
            GROUP_LIST=$(echo -n "[\"$JF_GROUP_UUID\",\"$ADMIN_GROUP_UUID\"]")
          fi
          $CURL -X PUT \
            -H "$AUTH_HDR" \
            -H "Content-Type: application/json" \
            -d "$GROUP_LIST" \
            "$PI_DIRECT/api/oidc/clients/$CLIENT_ID/allowed-user-groups"

          echo "Triggering jellarr sync..."
          systemctl start jellarr.service || true
        '';
      };
    };
  }
  (lib.optionalAttrs (options.services ? jellarr) {
    services.jellarr.config = {
      branding = {
        loginDisclaimer = ''<a href="/sso/OIDC/Start/pocketid" class="raised block emby-button button-submit" style="display:block;margin:1em 0;padding:0.9em;text-align:center;text-decoration:none;">Sign in with PocketID</a>'';
        splashscreenEnabled = false;
      };
      plugins = [{
        name = "OIDC RBAC";
        configuration = {
          Providers = [{
            ProviderId = "pocketid";
            DisplayName = "PocketID";
            Authority = "https://${pi.domain}";
            ClientId = "jellyfin";
            ClientSecret = "@OIDC_SECRET@";
            Scopes = "openid profile email";
            RoleClaim = "groups";
            UsernameClaim = "preferred_username";
            DisplayNameClaim = "name";
            PictureClaim = "picture";
            SyncProfileImage = true;
            Enabled = true;
            ButtonColor = "#4285F4";
            ButtonIcon = "";
            AdditionalParameters = "";
            ServerBaseUrl = "https://${jf.domain}";
          }];
          RoleMappings = [];
          DefaultProvider = "pocketid";
          AutoCreateUsers = true;
          DefaultRoleName = "";
        };
      }];
    };

    systemd.services.jellarr.preStart = lib.mkAfter ''
      if [ -f ${secretFile} ]; then
        ${pkgs.gnused}/bin/sed -i "s|@OIDC_SECRET@|$(cat ${secretFile})|" \
          /var/lib/jellarr/config/config.yml
      fi
    '';
  })
])
