# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — top-level module.
#
# Aggregates the tenant module and per-service placeholders. The flake's
# `nixosModules.default` ultimately imports this file (via default.nix).
#
# v0 architecture (see PLAN.md):
#   - Per-tenant: cococoir.tenant.<name> = { domain, adminUser, adminPasswordFile }
#   - All other values (subdomains, buckets, ports, OIDC clients) are
#     derived and readOnly. See ADR-011.
#   - No enable flags yet; every customer gets every known service.
#     See ADR-012.
{
  imports = [
    ./tenant.nix
    ./edge.nix
    ./client.nix
    ./services/jellyfin.nix
    ./services/cryptpad.nix
  ];
}
