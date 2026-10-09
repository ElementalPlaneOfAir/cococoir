# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/integrations/jellyfin-oidc — auto-configure the OIDC
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
  jf = config.fortress.services.jellyfin;
  dx = config.fortress.services.dex;
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

  secretFile = config.sops.secrets.oidc-jellyfin-secret.path;
in
mkIf oidcEnabled (lib.mkMerge [
  {
    systemd.services.dex.after = ["sops-install-secrets.service"];

    services.dex.settings.staticClients = lib.mkAfter [
      {
        id = "jellyfin";
        name = "Jellyfin";
        # The plugin derives its callback from ServerBaseUrl (the
        # clearnet canonical, incl. the /jellyfin base path); the
        # plane variants are registered so a plane-swapped callback
        # (planes.nix keeps the browser on its plane) is always a
        # known redirect_uri.
        redirectURIs =
          lib.optional (config.fortress.planes.clearnetOrigin != null)
            "${config.fortress.planes.clearnetOrigin}${jf.path}/sso/OIDC/Callback/dex"
          ++ lib.optional (config.fortress.planes.lanOrigin != null)
            "${config.fortress.planes.lanOrigin}${jf.path}/sso/OIDC/Callback/dex"
          ++ lib.optional (config.fortress.planes.i2pOrigin != null)
            "${config.fortress.planes.i2pOrigin}${jf.path}/sso/OIDC/Callback/dex";
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
    # jellarr's preStart substitutes the secret into its config, so it
    # must be able to read the file — not just dex (which runs the
    # substitution as root).
    sops.secrets.oidc-jellyfin-secret = {
      group = config.services.jellarr.group;
      mode = "0440";
    };

    services.jellarr.config = {
      branding = {
        loginDisclaimer = ''<a href="${jf.path}/sso/OIDC/Start/dex" class="raised block emby-button button-submit" style="display:block;margin:1em 0;padding:0.9em;text-align:center;text-decoration:none;">Sign in with Dex</a>'';
        splashscreenEnabled = false;
      };
      plugins = [{
        name = "OIDC RBAC";
        configuration = {
          Providers = [{
            ProviderId = "dex";
            DisplayName = "Dex";
            Authority = "http://127.0.0.1:${toString dx.port}/dex";
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
            ServerBaseUrl = "${config.fortress.planes.clearnetOrigin}${jf.path}";
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
          ${pkgs.gnused}/bin/sed -i "s|@OIDC_SECRET@|$(tr -d '\n' < ${secretFile})|" \
            /var/lib/jellarr/config/config.yml
        fi
      '')
    ];
  })
])
