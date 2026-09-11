# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/integrations/cryptpad-oidc — auto-configure CryptPad
# SSO with the platform's OIDC provider (Dex).
#
# SSO is enforced — local passwords are disabled.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkMerge;
  cp = config.fortress.services.cryptpad;
  dx = config.fortress.services.dex;
  oidcEnabled = cp.enable && dx.enable;
  secretFile = "/etc/dex/clients/cryptpad-secret";
in
mkIf oidcEnabled {
  services.cryptpad.settings.sso = {
    enabled = true;
    enforced = true;
    # Users may set a personal encryption password at registration or
    # later via Settings → Account → Own your drive. Without one the
    # drive key is derived from the seed alone, which the server
    # stores — so the admin can recover any password-less drive.
    cpPassword = true;
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

  systemd.services.fortress-cryptpad-oidc-secret = {
    description = "CryptPad OIDC client secret (Dex)";
    wantedBy = [ "multi-user.target" ];
    before = [ "dex.service" "cryptpad.service" ];
    path = [ pkgs.openssl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "fortress-cryptpad-oidc-secret" ''
        set -euo pipefail
        if [ ! -f "${secretFile}" ]; then
          openssl rand -hex -out "${secretFile}" 32
          chmod 0440 "${secretFile}"
        fi
        DST="/var/lib/fortress/cryptpad-config.js"
        mkdir -p "$(dirname "$DST")"
        cp ${builtins.toFile "cryptpad_config.js" ("module.exports = ${builtins.toJSON config.services.cryptpad.settings}")} "$DST" || exit 1
        cp ${builtins.toFile "cryptpad_sso_config.js" ("module.exports = ${builtins.toJSON config.services.cryptpad.settings.sso}")} "/var/lib/fortress/cryptpad-sso-config.js" || exit 1
        SECRET="$(${pkgs.coreutils}/bin/cat "${secretFile}")"
        ${pkgs.gnused}/bin/sed -i "s|@CRYPTPAD_SSO_SECRET@|$SECRET|" "$DST" || exit 1
        ${pkgs.gnused}/bin/sed -i "s|@CRYPTPAD_SSO_SECRET@|$SECRET|" "/var/lib/fortress/cryptpad-sso-config.js" || exit 1
        if ${pkgs.gnugrep}/bin/grep -q '@CRYPTPAD_SSO_SECRET@' "$DST"; then
          echo "fortress-cryptpad-oidc: unreplaced placeholder in $DST" >&2
          exit 1
        fi
        if ${pkgs.gnugrep}/bin/grep -q '@CRYPTPAD_SSO_SECRET@' "/var/lib/fortress/cryptpad-sso-config.js"; then
          echo "fortress-cryptpad-oidc: unreplaced placeholder in cryptpad-sso-config.js" >&2
          exit 1
        fi
        chmod 0444 "$DST"
        chmod 0444 "/var/lib/fortress/cryptpad-sso-config.js"
      '';
    };
  };

  systemd.services.dex = {
    after = [ "fortress-cryptpad-oidc-secret.service" ];
    serviceConfig.BindReadOnlyPaths = [ secretFile ];
  };

  services.dex.settings.staticClients = lib.mkAfter [
    {
      id = "cryptpad";
      name = "CryptPad";
      redirectURIs = [ "https://${cp.domain}/ssoauth" ];
      secretFile = secretFile;
    }
  ];

  systemd.services.cryptpad = {
    after = [ "fortress-cryptpad-oidc-secret.service" ];
    serviceConfig = {
      Environment = lib.mkAfter [
        "CRYPTPAD_CONFIG=/var/lib/fortress/cryptpad-config.js"
        "CRYPTPAD_SSO_CONFIG=/var/lib/fortress/cryptpad-sso-config.js"
      ];
      BindReadOnlyPaths = lib.mkAfter [
        "/var/lib/fortress/cryptpad-config.js"
        "/var/lib/fortress/cryptpad-sso-config.js"
      ];
    };
  };
}
