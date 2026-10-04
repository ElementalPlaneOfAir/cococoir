# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress sops auto-wire — `fortress.secrets.sopsFile` is the one-line
# switch that materializes the platform's secrets. When set, the secret
# inventory decrypts from that sops file (sealed to the device age key at
# /etc/fortress/system_age_keys.txt plus an owner key) and each consumer's
# *File option is wired with `mkDefault`. When null, nothing here applies —
# the customer wires secrets themselves (the dev VM / nixosTest path).
#
# This is a SIBLING of secrets.nix (which declares `fortress.secrets.*`). It
# only READS those options to gate contributions to FOREIGN option trees
# (sops.secrets / sops.templates / services.*). That is exactly the shape
# that avoids the module-system recursion the older auto-wire attempt hit
# (AGENTS.md cycle note) — the gate is a config read of a path this module
# does not itself declare.
#
# On-box layout (see .specify/specs/onbox-config-secrets/proposal.md):
#   /etc/fortress/system_age_keys.txt — device age private key (never in
#     git, never a store path). Secrets are sealed to this key + an owner
#     key, so the config's git source holds only ciphertext, and the box can
#     rotate secrets without the owner's master key.
{lib, config, ...}:
let
  sopsFile = config.fortress.secrets.sopsFile;
  inventory = config.fortress.secrets._inventory;
  adminSecretName = "fortress-admin-password-hash";
  adminSecretSpec = inventory.${adminSecretName};
  deviceKeyFile = "/etc/fortress/system_age_keys.txt";
in {
  config = lib.mkIf (sopsFile != null) {
    sops.defaultSopsFile = sopsFile;
    sops.age.keyFile = lib.mkDefault deviceKeyFile;

    sops.secrets.${adminSecretName} = {
      owner = adminSecretSpec.owner;
      group = adminSecretSpec.group;
      mode = adminSecretSpec.mode;
    };

    sops.templates."fortress-admin.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = "FORTRESS_ADMIN_PASSWORD_HASH=${config.sops.placeholder.${adminSecretName}}\n";
    };

    services.fortress-client.adminPasswordEnvFile =
      lib.mkDefault config.sops.templates."fortress-admin.env".path;
  };
}
