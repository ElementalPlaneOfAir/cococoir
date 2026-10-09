# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared demo-tier config, imported by the demo platform:
#
#   - nixosConfigurations/vmtest.nix        (QEMU dev VM)
#
# This file owns everything *platform-independent* about the demo:
# build-time secrets, the self-signed `*.vmtest.local` cert, the
# customer dashboard config (dashboard.nix), and the per-service
# public/Dex settings. Platform-specific bits (disks, bootloader,
# networking, SSH) stay in the importing configs.
#
# Hermetic by design: the sealed inventory and the TLS cert are
# generated at build time and the device age key is the only thing
# outside the store — the same shape a real box has after
# `fortress-bootstrap`, so the dev tier exercises the production
# secret path rather than a parallel one. No real network; TLS is a
# self-signed cert (production: fortress.tls.mode = "acme").
{
  config,
  lib,
  pkgs,
  ...
}: let
  devCreds = import ../nix/dev/dev-credentials.nix;

  # Build-time secret generation for the demo tier. In production,
  # sops-nix writes these files with mode 0440 / 0400 at
  # /run/secrets/<name>. We keep explicit wiring here because the
  # demo tier does NOT use sops-nix.

  # Build-time sealed inventory: mint every key the platform expects
  # (fortress.secrets._inventory), seal it to a device age key, and keep
  # only that key outside the store. Mirrors `fortress-bootstrap` on a
  # real box, so the dev tier takes the production secret path rather
  # than a parallel one. Values are random per build — it is a test —
  # but nothing in the platform ever mints at runtime.
  testSecrets =
    pkgs.runCommand "vmtest-sops" {
      buildInputs = [pkgs.age pkgs.sops pkgs.openssl];
    } ''
      set -euo pipefail
      mkdir -p $out
      age-keygen -o $out/device.agekey 2>/dev/null
      pub=$(age-keygen -y $out/device.agekey)
      # The dashboard hash must be a real bcrypt or the client rejects it.
      # This is the hash of `password` — the same one staticPasswords uses,
      # so the dev VM has one known credential.
      ADMIN_HASH='${devCreds.adminPasswordHash}'
      plaintext=$(mktemp)
      ${lib.concatStrings (lib.mapAttrsToList (
        name: _spec: let
          value =
            if name == "fortress-admin-password-hash"
            then ''"$ADMIN_HASH"''
            else ''"$(openssl rand -hex 32)"'';
        in ''printf '%s: "%s"\n' ${lib.escapeShellArg name} ${value} >> "$plaintext";''
      ) config.fortress.secrets._inventory)}
      grep -q '^fortress-admin-password-hash: "$2b$10$' "$plaintext" \
        || { echo "demo-base: fortress-admin-password-hash is not a bcrypt — the dashboard login can never succeed" >&2; exit 1; }
      sops --encrypt --age "$pub" --input-type yaml --output-type yaml "$plaintext" > "$out/secrets.enc.yaml"
      rm -f "$plaintext"
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
    "127.0.0.1" = ["vmtest.local" "auth.vmtest.local" "jellyfin.vmtest.local" "cryptpad.vmtest.local"
                      "radarr.vmtest.local" "sonarr.vmtest.local" "git.vmtest.local" "seerr.vmtest.local"];
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

  # The device age key is the one thing that lives outside the store.
  # On a real box `fortress-bootstrap` writes it; here the build does.
  environment.etc = {
    "vmtest-tls".source = testCerts;
    "fortress/system_age_keys.txt".source = "${testSecrets}/device.agekey";
  };

  fortress.secrets.sopsFile = "${testSecrets}/secrets.enc.yaml";
  # The sealed file is a build output, so it cannot be hashed at eval.
  sops.validateSopsFiles = false;

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

  # Dex's password hashes are config, not secrets — they are bcrypt
  # digests, and a real box carries them in config.nix the same way
  # (see limonene/archive/amon-sul/config.nix). This one is the hash of
  # `password`.
  services.dex.settings = {
    staticClients = [{
      id = "vmtest-cli";
      public = true;
      name = "vmtest CLI";
    }];

    staticPasswords = [{
      email = "admin@example.com";
      hash = devCreds.adminPasswordHash;
      username = "admin";
      userID = "08a8684b-db88-4b73-90a9-3cd1661f5466";
      groups = ["admins"];
      preferredUsername = "admin";
    }];
  };

  # Jellarr library config comes from the jellyfin service module's
  # defaults (libraries at <subvol>/library, downloads staging invisible
  # to Jellyfin) — deliberately NOT overridden here, so the demo
  # exercises and vmtest-wiring asserts the real composition. Do NOT
  # wrap jellarr config in lib.mkForce — mkForce on a submodule
  # silently discards the OIDC plugin config.
}
