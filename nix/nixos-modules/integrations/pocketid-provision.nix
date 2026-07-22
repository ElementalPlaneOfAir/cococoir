# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/pocketid-provision — declarative PocketID
# group provisioning.
#
# When pocketid is enabled AND has a static API key, this module
# idempotently provisions the `cococoir-admins` group. Service
# integrations (e.g. jellyfin-oidc.nix) depend on this group
# existing before they set their own OIDC client group
# restrictions.
#
# Human admin users are created out of band via PocketID's UI
# or its admin API — not through the NixOS config. The static
# API key user is the bootstrap admin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf getExe;
  hasApiKey = config.cococoir.services.pocketid.staticApiKeyFile or null != null;
  curl = getExe pkgs.curl;
  jq = getExe pkgs.jq;
  piPort = toString config.cococoir.services.pocketid.port;
in
mkIf hasApiKey {
  systemd.services.cococoir-pocketid-provision = {
    description = "Cococoir PocketID group provisioning";
    wantedBy = ["multi-user.target"];
    after = ["pocketid.service" "network.target"];
    requires = ["pocketid.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cococoir-pocketid-provision" ''
        set -euo pipefail

        PI="http://127.0.0.1:${piPort}"
        API_KEY_FILE="${config.cococoir.services.pocketid.staticApiKeyFile}"
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
        UUID=$(
          $C -H "$AUTH" "$PI/api/user-groups?search=cococoir-admins" \
          | $JQ -r '.data[] | select(.name == "cococoir-admins") | .id'
        )
        if [ -n "$UUID" ]; then
          echo "cococoir-admins already exists → $UUID"
        else
          UUID=$(
            $C -X POST -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"cococoir-admins","friendlyName":"Administrators"}' \
              "$PI/api/user-groups" | $JQ -r '.id'
          )
          echo "cococoir-admins created → $UUID"
        fi
      '';
    };
  };
}
