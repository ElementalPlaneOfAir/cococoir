# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/integrations/forgejo-oidc — auto-configure Forgejo's
# OIDC sign-in against the platform's Dex provider.
#
# When both Forgejo and Dex are enabled, this module:
#   1. Generates a client secret on first boot (oneshot, idempotent).
#   2. Adds the Forgejo OIDC client to Dex's staticClients.
#   3. Registers Dex as a Forgejo OIDC authentication source.
#
# Steps 1+2 are declarative (like jellyfin-oidc/cryptpad-oidc).
# Step 3 is imperative: OAuth2/OIDC authentication *sources* live in
# Forgejo's DB, not app.ini, so there is no Nix surface for them. A
# oneshot runs `forgejo admin auth add-oauth` after forgejo + dex are
# up (idempotent via `admin auth list`), then restarts forgejo —
# auth sources are cached in-process at startup, and a source added
# while running is served as 500 until restart (gitea #8356 class).
#
# The bootstrap runs as root (so it can `systemctl restart forgejo`)
# but invokes the forgejo CLI through runuser so any DB WAL/journal
# files it creates stay owned by the forgejo user.
#
# SSO redirect flow: Forgejo redirects the browser to the loopback
# dex issuer from its discovery doc; the contract factory's generic
# issuerLocationRewrite rewrites that Location to the clearnet dex
# origin on the forgejo vhost, and the dex module's i2p rewrite keeps
# the flow on the I2P plane. Nothing forgejo-specific is needed for
# the redirect hop.
{config, lib, pkgs, ...}:
let
  inherit (lib) mkIf;
  fj = config.fortress.services.forgejo;
  dx = config.fortress.services.dex;
  oidcEnabled = fj.enable && dx.enable;
  secretFile = "/etc/dex/clients/forgejo-secret";
  forgejoPkg = config.services.forgejo.package;
  discoveryUrl = "http://127.0.0.1:${toString dx.port}/dex/.well-known/openid-configuration";
in
mkIf oidcEnabled {
  systemd.tmpfiles.rules = [
    "d /etc/dex/clients 0755 root root -"
  ];

  systemd.services.fortress-forgejo-oidc-secret = {
    description = "Generate Forgejo OIDC client secret";
    wantedBy = ["multi-user.target"];
    before = ["dex.service" "forgejo.service"];
    path = [pkgs.openssl];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "gen-forgejo-secret" ''
        set -euo pipefail
        SECRET_FILE="${secretFile}"
        if [ ! -f "$SECRET_FILE" ]; then
          openssl rand -hex -out "$SECRET_FILE" 32
          chmod 0440 "$SECRET_FILE"
          chown root:forgejo "$SECRET_FILE"
        fi
      '';
    };
  };

  systemd.services.dex = {
    after = ["fortress-forgejo-oidc-secret.service"];
    serviceConfig.BindReadOnlyPaths = [secretFile];
  };

  services.dex.settings.staticClients = lib.mkAfter [
    {
      id = "forgejo";
      name = "Forgejo";
      redirectURIs = [
        "https://${fj.domain}/user/oauth2/dex/callback"
        "http://${fj.i2pDomain}/user/oauth2/dex/callback"
      ];
      secretFile = secretFile;
    }
  ];

  systemd.services.fortress-forgejo-oidc-bootstrap = {
    description = "Register Dex as a Forgejo OIDC authentication source";
    wantedBy = ["multi-user.target"];
    after = ["forgejo.service" "dex.service" "fortress-forgejo-oidc-secret.service"];
    requires = ["forgejo.service" "dex.service"];
    path = [
      pkgs.util-linux
      config.services.forgejo.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "forgejo-oidc-bootstrap" ''
        set -euo pipefail
        SECRET_FILE="${secretFile}"
        FORGEJO="${forgejoPkg}/bin/forgejo"
        WORK_PATH="${config.services.forgejo.stateDir}"
        CUSTOM_PATH="${config.services.forgejo.customDir}"
        RUNUSER="${pkgs.util-linux}/bin/runuser"
        # The auth source must not already exist (idempotency across boots).
        if $RUNUSER -u forgejo -- \
            "$FORGEJO" --work-path "$WORK_PATH" --custom-path "$CUSTOM_PATH" admin auth list \
          | ${pkgs.gnugrep}/bin/grep -qw "dex"; then
          exit 0
        fi
        SECRET="$(${pkgs.coreutils}/bin/cat "$SECRET_FILE")"
        $RUNUSER -u forgejo -- \
          "$FORGEJO" --work-path "$WORK_PATH" --custom-path "$CUSTOM_PATH" admin auth add-oauth \
            --name dex --provider openidConnect \
            --key forgejo --secret "$SECRET" \
            --auto-discover-url "${discoveryUrl}" \
            --scopes "openid profile email"
        ${pkgs.systemd}/bin/systemctl restart forgejo.service
      '';
    };
  };
}