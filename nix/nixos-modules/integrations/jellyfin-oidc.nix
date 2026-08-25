# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/integrations/jellyfin-oidc — auto-configure the OIDC
# RBAC plugin bridge between Jellyfin and Dex.
#
# When both Jellyfin and Dex are enabled, this module:
#   1. Installs the OIDC RBAC plugin DLLs via a systemd preStart.
#   2. Generates a client secret on first boot (oneshot, idempotent).
#   3. Adds the Jellyfin OIDC client to Dex's staticClients.
#   4. Configures jellarr with Dex as the OIDC provider.
#
# No API provisioning, no runtime group creation — everything is
# declarative Nix config. Groups come from Dex's staticPasswords
# (set by the customer in their config), propagated via the
# `groups` scope → `groups` OIDC claim → Jellyfin's RoleClaim.
#
# Plugin ID: d4e5f6a7-b8c9-0d1e-2f3a-4b5c6d7e8f90 (OIDC RBAC)
{config, lib, pkgs, options, ...}:
let
  inherit (lib) mkIf;
  jf = config.cococoir.services.jellyfin;
  dx = config.cococoir.services.dex;
  oidcEnabled = jf.enable && dx.enable;

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

  secretFile = "/etc/dex/clients/jellyfin-secret";
  jellarrGroup =
    if options.services ? jellarr
    then config.services.jellarr.group
    else "root";
in
mkIf oidcEnabled (lib.mkMerge [
  {
    systemd.tmpfiles.rules = [
      "d /etc/dex/clients 0755 root root -"
    ];

    systemd.services.cococoir-jellyfin-oidc-secret = {
      description = "Generate Jellyfin OIDC client secret";
      wantedBy = ["multi-user.target"];
      before = ["dex.service"];
      path = [pkgs.openssl];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "gen-jellyfin-secret" ''
          set -euo pipefail
          SECRET_FILE="${secretFile}"
          if [ ! -f "$SECRET_FILE" ]; then
            openssl rand -hex -out "$SECRET_FILE" 32
            chmod 0440 "$SECRET_FILE"
            chown root:${jellarrGroup} "$SECRET_FILE"
          fi
        '';
      };
    };

    systemd.services.dex = {
      after = ["cococoir-jellyfin-oidc-secret.service"];
      serviceConfig.BindReadOnlyPaths = [secretFile];
    };

    services.dex.settings.staticClients = lib.mkAfter [
      {
        id = "jellyfin";
        name = "Jellyfin";
        redirectURIs = ["https://${jf.domain}/sso/OIDC/Callback/dex"];
        secretFile = secretFile;
      }
    ];

    systemd.services.jellyfin.preStart = lib.mkBefore ''
      mkdir -p /var/lib/jellyfin/plugins/"OIDC RBAC"
      rm -f /var/lib/jellyfin/plugins/"OIDC RBAC"/*.dll
      ln -sf ${oidcPlugin}/* /var/lib/jellyfin/plugins/"OIDC RBAC"/
      chmod -R 770 /var/lib/jellyfin/plugins/"OIDC RBAC"
    '';
  }
  (lib.optionalAttrs (options.services ? jellarr) {
    services.jellarr.config = {
      branding = {
        loginDisclaimer = ''<a href="/sso/OIDC/Start/dex" class="raised block emby-button button-submit" style="display:block;margin:1em 0;padding:0.9em;text-align:center;text-decoration:none;">Sign in with Dex</a>'';
        splashscreenEnabled = false;
      };
      plugins = [{
        name = "OIDC RBAC";
        configuration = {
          Providers = [{
            ProviderId = "dex";
            DisplayName = "Dex";
            Authority = "https://${dx.domain}/dex";
            ClientId = "jellyfin";
            ClientSecret = "@OIDC_SECRET@";
            Scopes = "openid profile email groups";
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
          DefaultProvider = "dex";
          AutoCreateUsers = true;
          DefaultRoleName = "";
        };
      }];
    };

    systemd.services.jellarr.serviceConfig.ExecStartPre = lib.mkAfter [
      (pkgs.writeShellScript "jellarr-oidc-secret" ''
        set -e
        if [ -f ${secretFile} ]; then
          ${pkgs.gnused}/bin/sed -i "s|@OIDC_SECRET@|$(cat ${secretFile})|" \
            /var/lib/jellarr/config/config.yml
        fi
      '')
    ];
  })
])
