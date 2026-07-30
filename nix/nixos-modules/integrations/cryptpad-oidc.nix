# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/cryptpad-oidc — auto-configure CryptPad
# SSO with the platform's OIDC provider (Dex).
#
# SSO is enforced — local passwords are disabled.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkMerge;
  cp = config.cococoir.services.cryptpad;
  dx = config.cococoir.services.dex;
  oidcEnabled = cp.enable && dx.enable;
  secretFile = "/etc/dex/clients/cryptpad-secret";
in
mkIf oidcEnabled {
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

  systemd.services.cococoir-cryptpad-oidc-secret = {
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
        cp ${builtins.toFile "cryptpad_config.js" ("module.exports = ${builtins.toJSON config.services.cryptpad.settings}")} "$DST" || exit 1
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
    serviceConfig.BindReadOnlyPaths = [ secretFile ];
  };

  services.dex.settings.staticClients = lib.mkAfter [
    {
      id = "cryptpad";
      name = "CryptPad";
      redirectURIs = [ "https://${cp.domain}/oauth2/callback" ];
      secretFile = secretFile;
    }
  ];

  systemd.services.cryptpad = {
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
