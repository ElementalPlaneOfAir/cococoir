# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — top-level module.
#
# Aggregates the storage, tenant, and per-service modules. The
# flake's `nixosModules.default` ultimately imports this file
# (via default.nix).
#
# v2 architecture (see PLAN.md):
#   - cococoir.storage.* — Garage S3 + FUSE mounts, sops-nix secrets
#   - cococoir.tenant.<name> — per-tenant config (v0 B2B use case;
#     reused for v3 multi-tenant)
#   - cococoir.services.<name> — 4-option contract, FUSE-backed
#     data dirs
#   - services.cococoir-{edge,client} — v0 L4 forwarder systemd
#     units (no-op on a v2 single-machine with no WireGuard peer)
{
  imports = [
    ./storage/garage.nix
    ./tenant.nix
    ./edge.nix
    ./client.nix
    ./services/jellyfin.nix
    ./services/cryptpad.nix
  ];
}
