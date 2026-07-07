# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — module aggregator.
#
# The flake's `nixosModules.default` imports this file. Sub-modules are
# added here as v0 progresses (tenant.nix, pocketid.nix, garage.nix,
# caddy.nix, services/<name>.nix, ...).
{
  imports = [
    ./cococoir.nix
  ];
}
