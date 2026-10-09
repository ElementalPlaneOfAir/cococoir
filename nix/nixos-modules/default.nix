# SPDX-License-Identifier: AGPL-3.0-or-later
# Fortress v2 — module aggregator.
#
# The flake's `nixosModules.default` imports this file. Sub-modules are
# added here as v0 progresses (btrfs.nix,
# caddy.nix, services/<name>.nix, ...).
{
  imports = [
    ./fortress.nix
    # Secret material (sops.secrets / sops.templates) derived from the
    # sealed inventory. Every entry point pairs this aggregator with
    # sops-nix — see flake.nix nixosModulesWithJellarr and
    # nix/system-manager/fortress.nix.
    ./sops-wire.nix
  ];
}
