# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/secrets — the platform's sops-nix secret inventory.
#
# The customer-facing surface is one option:
#
#   cococoir.secrets.sopsFile = ./secrets.yaml;
#
# When set, the customer is expected to import sops-nix and
# declare `sops.secrets.<key>` for each key in the inventory
# below (or use the `nix run .#init` tool — v2.8 — to
# generate the encrypted YAML with random values for every
# key). The customer's `config.nix` then wires the *File
# options on each service from `config.sops.secrets.<key>.path`.
#
# Why not auto-wire? The auto-wiring pattern (this module
# reading `config.cococoir.secrets.sopsFile` in its `config`
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
    "garage-rpc-secret" = {
      owner = "garage";
      group = "garage";
      mode = "0400";
      description = ''
        Garage's RPC shared secret. Used by the bucket-init
        oneshot to authenticate to the cluster.
      '';
    };
    "garage-admin-token" = {
      owner = "garage";
      group = "garage";
      mode = "0400";
      description = ''
        Garage's admin API token. Used by the bucket-init
        oneshot and any admin operations.
      '';
    };
    "garage-metrics-token" = {
      owner = "garage";
      group = "garage";
      mode = "0400";
      description = "Garage's Prometheus metrics token.";
    };
    "s3-access-key-id" = {
      owner = "garage";
      group = "garage";
      mode = "0440";
      description = "S3 access key id, used by all FUSE mounts and native-S3 services.";
    };
    "s3-secret-access-key" = {
      owner = "garage";
      group = "garage";
      mode = "0400";
      description = "S3 secret access key, paired with s3-access-key-id.";
    };
    "pocketid-encryption-key" = {
      owner = "pocketid";
      group = "pocketid";
      mode = "0400";
      description = ''
        Pocket-ID's ENCRYPTION_KEY. Base64-encoded 32 bytes.
        The file MUST NOT have trailing CR/LF (pocket-id treats
        line terminators as part of the key; a stray newline
        fails decryption on restart).
      '';
    };
    "pocketid-static-api-key" = {
      owner = "pocketid";
      group = "pocketid";
      mode = "0400";
      description = ''
        Pocket-ID's STATIC_API_KEY. When set, pocket-id
        auto-creates a "Static API User" admin on first boot.
        Recommended for dev VMs and CI environments.
      '';
    };
    "jellarr-api-key" = {
      owner = "jellarr";
      group = "jellarr";
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
      owner = "jellarr";
      group = "jellarr";
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
  };
in
{
  options.cococoir.secrets.sopsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    example = "./secrets.yaml";
    description = ''
      Path to a sops-encrypted YAML containing all machine
      secrets. Set by the customer in their config.nix. When
      non-null, the customer also imports sops-nix
      (`sops-nix.nixosModules.sops`) and wires the *File
      options on each cococoir service from
      `config.sops.secrets.<key>.path`. See the inventory
      below for the list of keys. The `nix run .#init` tool
      (v2.8) generates the YAML with random values for every
      key in the inventory.

      When null (the default), the customer is responsible
      for supplying *File options explicitly with their own
      secret paths — this is the dev VM / nixosTest path
      where secrets are build-time-generated.
    '';
  };

  # The inventory is exposed for tooling (`nix eval
  # .#nixosConfigurations.<x>.config.cococoir.secrets._inventory`).
  # Internal — customers do not set or read this; the
  # `nix run .#init` / `nix run .#add-secret` tools are the
  # customer-facing interface.
  options.cococoir.secrets._inventory = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = inventory;
    internal = true;
    description = "Read-only inventory of secrets the platform expects. Tooling reads this.";
  };
}
