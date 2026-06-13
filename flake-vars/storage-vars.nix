# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Clan vars generators for the storage module.
#
# This file is auto-discovered by `import-tree ./modules/vars` in flake.nix
# and exposed as `flake.modules.nixos.storageVars`. Consumers add it to
# their machine imports:
#
#   imports = [ inputs.cococoir.modules.nixos.storageVars ];
#
# Generated secrets:
#   - storage-rpc-secret:    Cluster-shared RPC secret (32 random bytes hex).
#                            All nodes in the cluster need the same value.
#                            Shared = true.
#   - storage-global-key:    The S3 access key id + secret for the cluster's
#                            global key. Per-machine because the key
#                            generation runs on one node and propagates.
#
# The bucket init oneshot reads these paths, not user-supplied ones.
{...}: {
  flake.modules.nixos.storageVars = {
    clan.core.vars.generators.storage-rpc-secret = {
      share = true;
      files.rpc-secret = {};
      script = ''
        od -An -tx1 -N32 < /dev/urandom | tr -d ' \n' > $out/rpc-secret
      '';
      runtimeInputs = [];
    };

    clan.core.vars.generators.storage-global-key = {
      # The key generation runs on the cluster's first node; the secret
      # access key is then propagated to other nodes via the bucket-init
      # oneshot reading /var/lib/cococoir/garage/global/.
      # We don't put the secret in clan vars because garage generates the
      # keypair at runtime; we only stash the access key id here as a
      # reference. The actual secret lives on disk.
      files.access-key-id = {};
      script = ''
        # Placeholder: the real access-key-id is written by the
        # garage-bucket-init oneshot once garage has created the key.
        # The clan generator exists so the path is reserved in the
        # vars tree (and auditable) from the first deployment.
        echo "pending-runtime-generation" > $out/access-key-id
      '';
      runtimeInputs = [];
    };
  };
}
