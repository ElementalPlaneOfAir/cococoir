# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/secrets — the platform's sops-nix secret inventory.
#
# The customer-facing surface is one option:
#
#   cococoir.secrets.sopsFile = ./secrets.yaml;
#
# The actual `sops.secrets.<name>` declarations live in the
# customer's `secrets.yaml` and are wired by sops-nix. Cococoir
# documents the inventory of keys the platform expects; the
# `nix run .#init` tool (v2.8 backlog) generates the YAML with
# random values for every key, encrypted with the customer's
# age key, so the customer never hand-edits it.
#
# In a customer's config.nix the wiring looks like:
#
#   imports = [
#     cococoir.nixosModules.default
#     sops-nix.nixosModules.sops
#   ];
#
#   cococoir = {
#     secrets.sopsFile = ./secrets.yaml;
#     storage.secrets = {
#       rpcSecretFile         = config.sops.secrets."garage-rpc-secret".path;
#       adminTokenFile        = config.sops.secrets."garage-admin-token".path;
#       metricsTokenFile      = config.sops.secrets."garage-metrics-token".path;
#       accessKeyIdFile       = config.sops.secrets."s3-access-key-id".path;
#       secretAccessKeyFile   = config.sops.secrets."s3-secret-access-key".path;
#     };
#     services.pocketid = {
#       enable             = true;
#       encryptionKeyFile  = config.sops.secrets."pocketid-encryption-key".path;
#       staticApiKeyFile   = config.sops.secrets."pocketid-static-api-key".path;
#     };
#   };
#
# That's the only secret-related boilerplate. The customer
# imports sops-nix (one line), points sopsFile at the file,
# and references sops paths in *File options.
#
# In dev VMs (vmtest, nixosTest) leave `cococoir.secrets.sopsFile`
# at its default (null) and supply *File options directly with
# build-time-generated paths. This module is inert when
# sopsFile is null; no sops reference is made.
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
      null (the default), the customer is responsible for
      supplying *File options explicitly with their own secret
      paths — this is the dev VM / nixosTest path.

      When non-null, the customer imports sops-nix
      (`sops-nix.nixosModules.sops`) and references sops paths
      in *File options:

        cococoir.storage.secrets.rpcSecretFile =
          config.sops.secrets."garage-rpc-secret".path;

      See the module header for the full inventory. The
      `nix run .#init` tool (v2.8) generates the YAML with
      random values for every key, encrypted with the
      customer's age key, so the customer never hand-edits
      secrets.yaml.
    '';
  };

  # The inventory is exposed as documentation, not via options
  # (so adding a secret is a doc change here + a manual
  # `nix run .#add-secret <key>` call, not a module-system
  # event). This is intentional: the lazy evaluation of the
  # NixOS module system makes conditional sops.* declarations
  # recursive in dev VMs, and the customer paying attention to
  # the inventory here is a feature, not a bug.
  #
  # The inventory attrset is reachable as
  # `cococoir.secrets._inventory` for tooling (`nix eval
  # .#nixosConfigurations.<x>.config.cococoir.secrets._inventory`).
  options.cococoir.secrets._inventory = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = inventory;
    internal = true;
    description = "Read-only inventory of secrets the platform expects. Tooling reads this.";
  };
}
