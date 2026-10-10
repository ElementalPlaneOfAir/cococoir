# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/secrets — the platform's sops-nix secret inventory.
#
# The customer-facing surface is one option:
#
#   fortress.secrets.sopsFile = ./secrets.yaml;
#
# When set, the customer is expected to import sops-nix and
# declare `sops.secrets.<key>` for each key in the inventory
# below (or use the `nix run .#init` tool — v2.8 — to
# generate the encrypted YAML with random values for every
# key). The customer's `config.nix` then wires the *File
# options on each service from `config.sops.secrets.<key>.path`.
#
# Why not auto-wire? The auto-wiring pattern (this module
# reading `config.fortress.secrets.sopsFile` in its `config`
# block to conditionally declare `sops.secrets.<key>` and
# wire the *File options) creates an evaluation cycle in
# the NixOS module system — the gate depends on the same
# option the module declares. We tried splitting the
# auto-wiring into a sibling module and using
# `lib.optionalAttrs`/`lib.mkIf`; both recursed. The cleanest
# path is the customer doing the wiring explicitly. It's
# ~10 lines per customer config, the inventory is documented
# here, and the `nix run .#init` tool generates the YAML
# automatically. Total customer config is still well under
# 50 lines.
{lib, ...}:

  let
  inventory = {
    "jellarr-api-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        Jellyfin API key for jellarr. On first boot, the
        `jellarr-api-key-bootstrap.service` oneshot inserts
        this key into Jellyfin's SQLite database. After that,
        jellarr authenticates to Jellyfin's REST API with this
        key (sent as `X-Emby-Token: <key>`). Trimmed of
        whitespace at insertion time.
      '';
    };
    "jellyfin-admin-password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        Password for the Jellyfin admin user that jellarr
        creates on first boot. Plaintext in the file
        (whitespace is trimmed by jellarr). Customer generates
        a strong value via `nix run .#init` (v2.8) or their
        password manager; the dev VM generates a random one
        at build time.
      '';
    };
    "fortress-admin-password-hash" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        A bcrypt hash (cost >= 10) of the box's dashboard admin
        password — the control plane that edits global settings
        and users. The client service loads it via
        `services.fortress-client.adminPasswordEnvFile` as
        `FORTRESS_ADMIN_PASSWORD_HASH`. Required: the dashboard
        has no unauthenticated mode, so fortress-client refuses
        to start without it. Wire a sops template rendering
        `FORTRESS_ADMIN_PASSWORD_HASH=''${fortress-admin-password-hash}`
        to this secret for T7.
      '';
    };
    "radarr-api-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        Radarr's own API key. Radarr ignores the
        RADARR__SERVER__APIKEY override once config.xml exists,
        so this value is pinned into config.xml at start and is
        also what the media handshake authenticates with.
      '';
    };
    "sonarr-api-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        Sonarr's own API key. Same pinning and handshake role as
        radarr-api-key.
      '';
    };
    "seerr-admin-password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        Password for the `seerr-bootstrap` Jellyfin admin user
        that the media handshake creates on first boot, then
        signs Seerr in through. Seerr has no local admin-creation
        route, so this is its only first-boot admin path.
      '';
    };
    "cryptpad-jwt-secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        CryptPad's JWT signing key. CryptPad refuses to start
        without one and silently derives an ephemeral key, which
        invalidates every session on restart.
      '';
    };
    "oidc-jellyfin-secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        OIDC client secret shared between dex and Jellyfin.
      '';
    };
    "oidc-cryptpad-secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        OIDC client secret shared between dex and CryptPad.
      '';
    };
    "oidc-forgejo-secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        OIDC client secret shared between dex and Forgejo.
      '';
    };
    "oidc-gate-secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        OIDC client secret shared between dex and the forward-auth gate
        (oauth2-proxy). The gate is what stands between a LAN browser and
        radarr/sonarr/qbittorrent, whose own logins are disabled.
      '';
    };
    "gate-cookie-secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      description = ''
        Seed for the gate's session cookie (oauth2-proxy). Must be 16, 24
        or 32 bytes, base64-encoded — `nix run .#init` generates one that
        fits. Rotating it signs every user out of the gated services.
      '';
    };
  };
in
{
  options.fortress.secrets.sopsFile = lib.mkOption {
    type = lib.types.path;
    example = "./secrets/secrets.enc.yaml";
    description = ''
      Path to the sops-encrypted YAML holding every secret in the
      inventory below. Required: there is exactly one mechanism for
      secret material, and it is sealed ciphertext in the store — the
      value is deterministic, and only the device age key at
      /etc/fortress/system_age_keys.txt can open it. Nothing mints a
      secret at boot; `nix run .#init` (or `fortress-bootstrap`)
      generates and seals the whole inventory once.

      `sops-wire.nix` turns this one line into every `sops.secrets.*`
      declaration the platform needs, so no service has its own
      secret-plumbing option.
    '';
  };

  # The inventory is exposed for tooling (`nix eval
  # .#nixosConfigurations.<x>.config.fortress.secrets._inventory`).
  # Internal — customers do not set or read this; the
  # `nix run .#init` / `nix run .#add-secret` tools are the
  # customer-facing interface.
  options.fortress.secrets._inventory = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = inventory;
    internal = true;
    description = "Read-only inventory of secrets the platform expects. Tooling reads this.";
  };
}
