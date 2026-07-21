# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/pocketid-provision — declarative PocketID
# user and group provisioning.
#
# When pocketid is enabled AND has a static API key, this module
# idempotently provisions:
#   1. The `cococoir-admins` group
#   2. A human admin user (if `adminUser` is configured)
#   3. A one-time login code so the admin can enroll their passkey
#
# Groups are queried by name before creation so repeated runs are
# safe. The login code is logged to journald
# (`journalctl -u cococoir-pocketid-provision.service`) for the
# customer to grab and use for passkey setup.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf getExe optionalAttrs;
  pi = config.cococoir.services.pocketid;
  hasApiKey = pi.staticApiKeyFile or null != null;
  hasAdminUser = hasApiKey && pi.adminUser != null;
  provisionEnabled = hasApiKey;
  curl = getExe pkgs.curl;
  jq = getExe pkgs.jq;
  piPort = toString pi.port;
in
mkIf provisionEnabled (
  lib.mkMerge [
    {
      systemd.services.cococoir-pocketid-provision = {
        description = "Cococoir PocketID declarative provisioning";
        wantedBy = ["multi-user.target"];
        after = ["pocketid.service" "network.target"];
        requires = ["pocketid.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "cococoir-pocketid-provision" (
            let
              adminUserJson =
                if hasAdminUser
                then
                  let au = pi.adminUser;
                  in
                    ''"$(${jq} -n \
                      --arg username "${au.username}" \
                      --arg firstName "${au.firstName}" \
                      --argjson email ${
                        if au.email != null
                        then ''"${au.email}"''
                        else "null"
                      } \
                      --argjson isAdmin true \
                      '{username:$username,firstName:$firstName,email:$email,isAdmin:$isAdmin}')"''
                else ''""'';
            in
            ''
              set -euo pipefail

              PI="http://127.0.0.1:${piPort}"
              API_KEY_FILE="${pi.staticApiKeyFile}"
              C="${curl} -sf --max-time 10 --connect-timeout 5"
              JQ="${jq}"

              API_KEY=$(cat "$API_KEY_FILE")
              AUTH="X-API-Key: $API_KEY"

              echo "Waiting for PocketID at $PI..."
              for i in $(seq 1 30); do
                if $C -H "$AUTH" -o /dev/null "$PI/api/oidc/clients"; then
                  break
                fi
                sleep 2
              done

              echo "Ensuring cococoir-admins group..."
              ADMIN_GROUP_UUID=$(
                $C -H "$AUTH" "$PI/api/user-groups?search=cococoir-admins" \
                | $JQ -r '.data[] | select(.name == "cococoir-admins") | .id'
              )
              if [ -z "$ADMIN_GROUP_UUID" ]; then
                echo "Creating cococoir-admins group..."
                ADMIN_GROUP_UUID=$(
                  $C -X POST -H "$AUTH" -H "Content-Type: application/json" \
                    -d '{"name":"cococoir-admins","friendlyName":"Administrators"}' \
                    "$PI/api/user-groups" | $JQ -r '.id'
                )
                echo "cococoir-admins → $ADMIN_GROUP_UUID"
              else
                echo "cococoir-admins already exists → $ADMIN_GROUP_UUID"
              fi

              ${lib.optionalString hasAdminUser ''
                ADMIN_USERNAME="${pi.adminUser.username}"

                echo "Ensuring admin user $ADMIN_USERNAME..."
                USER_UUID=$(
                  $C -H "$AUTH" "$PI/api/users?search=$ADMIN_USERNAME" \
                  | $JQ -r --arg u "$ADMIN_USERNAME" '.data[] | select(.username == $u) | .id'
                )

                if [ -z "$USER_UUID" ]; then
                  echo "Creating admin user $ADMIN_USERNAME..."
                  USER_JSON=${adminUserJson}
                  USER_UUID=$(
                    $C -X POST -H "$AUTH" -H "Content-Type: application/json" \
                      -d "$USER_JSON" \
                      "$PI/api/users" | $JQ -r '.id'
                  )
                  echo "User $ADMIN_USERNAME → $USER_UUID"

                  echo "Adding $ADMIN_USERNAME to cococoir-admins group..."
                  $C -X PUT -H "$AUTH" -H "Content-Type: application/json" \
                    -d "{\"userGroupIds\":[\"$ADMIN_GROUP_UUID\"]}" \
                    "$PI/api/users/$USER_UUID/user-groups" > /dev/null

                  echo "Generating one-time login code..."
                  TOKEN_RESP=$($C -X POST -H "$AUTH" -H "Content-Type: application/json" \
                    -d '{}' \
                    "$PI/api/users/$USER_UUID/one-time-access-token")
                  LOGIN_CODE=$(echo "$TOKEN_RESP" | $JQ -r '.token')
                  echo ""
                  echo "  ╔══════════════════════════════════════════════════════════════╗"
                  echo "  ║  Admin passkey setup                                        ║"
                  echo "  ║                                                             ║"
                  echo "  ║  Visit: https://${pi.domain}/login                          ║"
                  echo "  ║  Enter login code: $LOGIN_CODE                              ║"
                  echo "  ║                                                             ║"
                  echo "  ║  This code expires in 15 minutes.                           ║"
                  echo "  ╚══════════════════════════════════════════════════════════════╝"
                  echo ""
                else
                  echo "Admin user $ADMIN_USERNAME already exists → $USER_UUID"
                fi
              ''}
            ''
          );
        };
      };
    }
  ]
)
