# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/cryptpad-oidc — auto-configure CryptPad
# SSO with the platform's OIDC provider (Dex or Pocket-ID).
#
# Dex is preferred when both providers are enabled. CryptPad SSO
# is enforced — local passwords are disabled.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkMerge;
  cp = config.cococoir.services.cryptpad;
  dx = config.cococoir.services.dex;

  mkDex = {
    services.cryptpad.settings.sso = {
      enabled = true;
      enforced = true;
      cpPassword = false;
      forceCpPassword = false;
      list = [
        {
          name = "dex";
          type = "oidc";
          url = "https://${dx.domain}/dex";
          client_id = "cryptpad";
          client_secret = "@CRYPTPAD_SSO_SECRET@";
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d /etc/dex/clients 0755 root root -"
    ];

    systemd.services.cococoir-cryptpad-oidc-secret = let
      secretFile = "/etc/dex/clients/cryptpad-secret";
    in {
      description = "CryptPad OIDC client secret (Dex)";
      wantedBy = [ "multi-user.target" ];
      before = [ "dex.service" "cryptpad.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cococoir-cryptpad-oidc-secret" ''
          set -euo pipefail
          if [ ! -f "${secretFile}" ]; then
            openssl rand -hex -out "${secretFile}" 32
            chmod 0440 "${secretFile}"
          fi
          DST="/var/lib/cococoir/cryptpad-config.js"
          mkdir -p "$(dirname "$DST")"
          cp ${builtins.toFile "cryptpad_config_d.js" ("module.exports = ${builtins.toJSON config.services.cryptpad.settings}")} "$DST" || exit 1
          SECRET="$(${pkgs.coreutils}/bin/cat "${secretFile}")"
          ${pkgs.gnused}/bin/sed -i "s|@CRYPTPAD_SSO_SECRET@|$SECRET|" "$DST" || exit 1
          if ${pkgs.gnugrep}/bin/grep -q '@CRYPTPAD_SSO_SECRET@' "$DST"; then
            echo "cococoir-cryptpad-oidc: unreplaced placeholder in $DST" >&2
            exit 1
          fi
          chmod 0444 "$DST"
        '';
      };
    };

    systemd.services.dex = {
      after = [ "cococoir-cryptpad-oidc-secret.service" ];
      serviceConfig.BindReadOnlyPaths = [ "/etc/dex/clients/cryptpad-secret" ];
    };

    services.dex.settings.staticClients = lib.mkAfter [
      {
        id = "cryptpad";
        name = "CryptPad";
        redirectURIs = [ "https://${cp.domain}/oauth2/callback" ];
        secretFile = "/etc/dex/clients/cryptpad-secret";
      }
    ];
  };

  mkPocketid = pidPort: pidDomain: pidApiKeyFile: {
    assertions = [
      {
        assertion = pidApiKeyFile != null;
        message = ''
          cococoir.integrations.cryptpad-oidc: Pocket-ID requires
          `cococoir.services.pocketid.staticApiKeyFile` to register
          the CryptPad OIDC client via Pocket-ID's admin API.
        '';
      }
    ];

    services.cryptpad.settings.sso = {
      enabled = true;
      enforced = true;
      cpPassword = false;
      forceCpPassword = false;
      list = [
        {
          name = "pocketid";
          type = "oidc";
          url = "https://${pidDomain}";
          client_id = "cryptpad";
          client_secret = "@CRYPTPAD_SSO_SECRET@";
        }
      ];
    };

    systemd.services.cococoir-cryptpad-oidc-secret = let
      secretFile = "/var/lib/cococoir/cryptpad-pocketid-secret";
    in {
      description = "CryptPad OIDC client secret (Pocket-ID)";
      wantedBy = [ "multi-user.target" ];
      before = [ "cryptpad.service" ];
      requires = [ "pocketid.service" ];
      after = [ "pocketid.service" ];
      path = with pkgs; [ curl jq coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cococoir-cryptpad-oidc-secret" ''
          set -euo pipefail

          if [ ! -f "${secretFile}" ]; then
            openssl rand -hex -out "${secretFile}" 32
            chmod 0440 "${secretFile}"
          fi

          SECRET="$(cat "${secretFile}")"
          API_URL="http://127.0.0.1:${toString pidPort}/api/oidc/clients"
          STATIC_KEY="$(cat "${pidApiKeyFile}")"

          echo "cococoir-cryptpad-oidc: waiting for Pocket-ID API..."
          for i in $(seq 1 30); do
            if curl -sf -o /dev/null \
                 -H "Authorization: Bearer $STATIC_KEY" \
                 "$API_URL" 2>/dev/null; then
              echo "cococoir-cryptpad-oidc: Pocket-ID API ready"
              break
            fi
            if [ "$i" -eq 30 ]; then
              echo "cococoir-cryptpad-oidc: Pocket-ID API unreachable after 30 attempts" >&2
              exit 1
            fi
            sleep 2
          done

          EXISTING=$(curl -sf -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $STATIC_KEY" \
            "$API_URL/cryptpad" 2>/dev/null || echo "000")

          if [ "$EXISTING" = "404" ]; then
            echo "cococoir-cryptpad-oidc: creating Pocket-ID OIDC client..."
            curl -sf -H "Authorization: Bearer $STATIC_KEY" \
              -H "Content-Type: application/json" \
              -d '{"name":"CryptPad","callbackURLs":["https://${cp.domain}/oauth2/callback"],"logoutCallbackURLs":[],"isPublic":false,"pkceEnabled":true,"skipConsent":true}' \
              "$API_URL" > /dev/null
          fi

          echo "cococoir-cryptpad-oidc: setting client secret..."
          curl -sf -H "Authorization: Bearer $STATIC_KEY" \
            -H "Content-Type: application/json" \
            -d '{"secret":"'"$SECRET"'"}' \
            "$API_URL/cryptpad/secret" > /dev/null

          DST="/var/lib/cococoir/cryptpad-config.js"
          mkdir -p "$(dirname "$DST")"
          cp ${builtins.toFile "cryptpad_config_p.js" ("module.exports = ${builtins.toJSON config.services.cryptpad.settings}")} "$DST" || exit 1
          ${pkgs.gnused}/bin/sed -i "s|@CRYPTPAD_SSO_SECRET@|$SECRET|" "$DST" || exit 1
          if ${pkgs.gnugrep}/bin/grep -q '@CRYPTPAD_SSO_SECRET@' "$DST"; then
            echo "cococoir-cryptpad-oidc: unreplaced placeholder in $DST" >&2
            exit 1
          fi
          chmod 0444 "$DST"
        '';
      };
    };
  };
in
{
  config = mkMerge [
    (mkIf (cp.enable && dx.enable) mkDex)

    (mkIf (cp.enable && config.cococoir.services.pocketid.enable && !dx.enable)
      (mkPocketid
        config.cococoir.services.pocketid.port
        config.cococoir.services.pocketid.domain
        config.cococoir.services.pocketid.staticApiKeyFile
      ))

    {
      systemd.services.cryptpad = mkIf (cp.enable && (dx.enable || config.cococoir.services.pocketid.enable)) {
        after = [ "cococoir-cryptpad-oidc-secret.service" ];
        serviceConfig = {
          Environment = lib.mkAfter [
            "CRYPTPAD_CONFIG=/var/lib/cococoir/cryptpad-config.js"
          ];
          BindReadOnlyPaths = lib.mkAfter [
            "/var/lib/cococoir/cryptpad-config.js"
          ];
        };
      };
    }
  ];
}
