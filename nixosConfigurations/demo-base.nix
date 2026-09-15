# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared demo-tier config, imported by both demo platforms:
#
#   - nixosConfigurations/vmtest.nix        (QEMU dev VM)
#   - nixosConfigurations/fortress-container.nix (full-OS container)
#
# This file owns everything *platform-independent* about the demo:
# build-time secrets, the self-signed `*.vmtest.local` cert, the
# customer dashboard config (dashboard.nix), and the per-service
# public/Dex settings. Platform-specific bits (disks, bootloader,
# networking, SSH) stay in the importing configs.
#
# Hermetic by design: secrets and the TLS cert are generated at
# build time, no sops-nix, no real network. Production uses
# sops-nix with the user's age key and a real ACME certificate
# (see fortress.tls.mode = "acme").
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Build-time secret generation for the demo tier. In production,
  # sops-nix writes these files with mode 0440 / 0400 at
  # /run/secrets/<name>. We keep explicit wiring here because the
  # demo tier does NOT use sops-nix.

  # Build-time Dex secrets: OIDC client secret for Jellyfin
  # and a bcrypt password hash for the test admin user.
  # Dex's replace-secret reads the client secret file at
  # startup and substitutes its path in the YAML config with
  # the file content. The bcrypt hash goes into Dex's
  # staticPasswords.
  testDexSecrets =
    pkgs.runCommand "vmtest-dex-secrets" {
      buildInputs = [pkgs.openssl pkgs.apacheHttpd];
    } ''
      mkdir -p $out
      openssl rand -hex -out $out/jellyfin-client-secret 32
      openssl rand -hex -out $out/cryptpad-client-secret 32
      chmod 0440 $out/jellyfin-client-secret $out/cryptpad-client-secret
      htpasswd -bnBC 10 "" password | cut -d: -f2 | tr -d '\n' > $out/admin-password-hash
    '';

  # Build-time self-signed TLS cert for the
  # `*.vmtest.local` cookie-jar. The browser will warn
  # about it (it's a demo, the cert changes every build);
  # -k on curl / "Accept the risk" in the browser gets past it.
  # In production, `fortress.tls.mode = "acme"` makes Caddy
  # issue a real cert.
  testCerts =
    pkgs.runCommand "vmtest-tls" {
      buildInputs = [pkgs.openssl];
    } ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout $out/key.pem -out $out/cert.pem -days 365 \
        -subj "/CN=*.vmtest.local" \
        -addext "subjectAltName=DNS:vmtest.local,DNS:*.vmtest.local" \
        >/dev/null 2>&1
      chmod 0444 $out/cert.pem
      chmod 0400 $out/key.pem
    '';
in {
  imports = [
    ./dashboard.nix
    (import ../nix/nixos-modules)
  ];

  system.stateVersion = "25.11";

  networking.hosts = {
    "127.0.0.1" = ["auth.vmtest.local" "jellyfin.vmtest.local" "cryptpad.vmtest.local"
                      "radarr.vmtest.local" "sonarr.vmtest.local"];
  };

  security.pki.certificates = [
    (builtins.readFile "${testCerts}/cert.pem")
  ];

  # Platform-wide config. baseDomain + hostname come from
  # dashboard.nix (the customer-edited file). tls.mode does the work
  # that used to live in every per-vhost `extraConfig`:
  #   - service `domain` options default to `<svc>.vmtest.local`
  #     (override per-service if you need a non-conventional name)
  #   - Caddy's `tls` directive is emitted automatically from
  #     `fortress.tls.{certFile, keyFile}` for every vhost
  #   - `services.caddy.enable = true` and the per-service
  #     `fortress.services.<name>.enable = true` together drive
  #     vhost creation via the contract factory
  fortress.tls = {
    mode = "self-signed";
    certFile = "/etc/vmtest-tls/cert.pem";
    keyFile = "/etc/vmtest-tls/key.pem";
  };

  # Build-time secrets mounted at well-known paths.
  environment.etc = {
    "vmtest-tls".source = testCerts;
    "vmtest-dex-secrets".source = testDexSecrets;
  };

  # Caddy: just enable. Every fortress.services.<name> with
  # enable = true registers a vhost via the contract factory,
  # which pulls `tls` from fortress.tls and `reverse_proxy` /
  # 403 from `public`. No per-vhost boilerplate here.
  #
  # The `email` option is left at its default (null) — Caddy
  # doesn't try ACME for `*.vmtest.local` (no real DNS), and
  # `email = ""` is a parse error.
  services.caddy.enable = true;

  # Jellyfin service. `enable` comes from dashboard.nix. Domain defaults
  # to jellyfin.vmtest.local via fortress.baseDomain. Datasets
  # auto-declared by the jellyfin module.
  fortress.services.jellyfin = {
    public = true;
  };

  fortress.services.cryptpad = {
    public = true;
  };

  fortress.services.radarr = {
    public = false;
  };
  fortress.services.sonarr = {
    public = false;
  };

  # Dex: self-hosted OIDC provider with email+password auth.
  # Domain defaults to auth.vmtest.local via fortress.baseDomain.
  # Users are declared in staticPasswords — no setup wizard, no
  # API provisioning. Groups flow through the `groups` OIDC scope
  # so Jellyfin picks them up as role claims.
  fortress.services.dex = {
    public = true;
  };

  # Build-time secret files wired into Dex and jellarr.
  # The generated Jellyfin client secret lives in
  # /etc/dex/clients/jellyfin-secret; the fortress-jellyfin-oidc-secret
  # oneshot copies it there on first boot (idempotent within a VM
  # overlay). The bcrypt hash goes directly into staticPasswords.
  services.dex.settings = {
    staticClients = [{
      id = "vmtest-cli";
      public = true;
      name = "vmtest CLI";
    }];

    staticPasswords = let
      hash = builtins.readFile "${testDexSecrets}/admin-password-hash";
    in [{
      email = "admin@example.com";
      hash = hash;
      username = "admin";
      userID = "08a8684b-db88-4b73-90a9-3cd1661f5466";
      groups = ["admins"];
      preferredUsername = "admin";
    }];
  };

  environment.etc."dex/clients/jellyfin-secret".source =
    "${testDexSecrets}/jellyfin-client-secret";

  environment.etc."dex/clients/cryptpad-secret".source =
    "${testDexSecrets}/cryptpad-client-secret";

  # Jellarr library config comes from the jellyfin service module's
  # defaults (libraries at <subvol>/library, downloads staging invisible
  # to Jellyfin) — deliberately NOT overridden here, so the demo
  # exercises and vmtest-wiring asserts the real composition. Do NOT
  # wrap jellarr config in lib.mkForce — mkForce on a submodule
  # silently discards the OIDC plugin config.
}
