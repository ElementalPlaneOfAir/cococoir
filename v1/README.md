# cococoir v1 — LEGACY, FROZEN

> **This codebase is soft-deprecated.** See `../PLAN.md` for the
> active product roadmap (v0/v2/v3/v4). v1 is preserved as a
> reference; features are ported from here to v2 one piece at a
> time. No new development on v1.

## Status

- **Frozen at v1** — clan-core-based home server. Never deployed on
  new systems, never updated. The customer (amon-sul) runs v0 (the
  rathole-based predecessor) and migrates to v2 once v2's foundation
  is solid.
- **Kept as a reference** — the storage layer, the FUSE mount
  pattern, the bucket-init oneshot logic, the per-service modules
  with the 4-option contract: all worth reading when porting
  features to v2.
- **The clan wiring is not expected to keep working.** The
  `flake.nix` and `flake.lock` here are not kept in sync with
  upstream clan-core. If you need to evaluate v1, pin a clan-core
  version known to work; otherwise, just read the code.

## What v1 has that v2 is porting

| v1 | v2 status |
|----|-----------|
| `cococoir/storage` option tree | Ported to `../nix/nixos-modules/storage/options.nix` |
| `cococoir/garage` clan-service | Ported to `../nix/nixos-modules/storage/garage.nix` (clan → sops) |
| `bucket-init.sh` | Ported to `../nix/nixos-modules/storage/bucket-init.sh` (env var renamed) |
| `services/{jellyfin,nextcloud,cryptpad,...}.nix` (4-option contract) | Pending port — see `../PLAN.md` v2.2 / v2.3 / v2.13 / v2.14 |
| `caddy` reverse proxy | Pending port — v2 |
| `pocketid` OIDC | Pending port — v2.10 |
| The `tunnel/` sub-project (rathole-based) | **Replaced** by v0's cococoir-edge/client (in `../nix/packages/cococoir/`). v0 is the modern L4 proxy; v1's rathole is retired. |

## License

AGPL-3.0-or-later. Every source file in v1 carries the matching
SPDX header.

## Do not add new code here

If you're porting a feature, do it in `../nix/nixos-modules/` (for
modules), `../nix/packages/cococoir/` (for Go), or wherever the
target component lives. Don't edit v1 in place. v1 is read-only
reference; v2 is the active target.
