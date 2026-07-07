# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Agent Context

Cococoir v2 is the multi-tenant evolution of cococoir. Currently in early
development (Day 1-2 of the v0 build plan).

## Architecture (target)

Per-tenant self-hosting. Each customer is a NixOS machine configured via:

- `cococoir.tenant.<name>.domain`
- `cococoir.tenant.<name>.adminUser`
- `cococoir.tenant.<name>.adminPasswordFile`

…with subdomains (`auth.${domain}` for PocketID, `<service>.${domain}` for
services), OIDC clients, storage buckets, and certs all derived from these
three inputs. See `PLAN.md` for the full design.

## Current state (Day 1-2)

Project skeleton only. The `cococoir.tenant.<name>` option exists as a
freeform attrset with no logic. Nothing is wired up yet. `nix flake check`
passes with one placeholder test.

## Structure

| Path | Purpose |
|------|---------|
| `flake.nix` | flake-parts flake. Minimal inputs: nixpkgs, flake-parts, import-tree. |
| `nix/nixos-modules/cococoir.nix` | Top-level option tree. `cococoir.tenant.<name>` placeholder. |
| `nix/nixos-modules/default.nix` | Module aggregator. Sub-modules are added here. |
| `nix/tests/default.nix` | Test suite. One placeholder `nixosTest` for now. |
| `nix/lib/` | Shared Nix library functions (empty for now). |
| `scripts/` | Operator scripts (empty for now). |
| `v1/` | Frozen v1 code. See `v1/AGENTS.md`. Will not be updated. |
| `PLAN.md` | The v2 build plan. **Read first.** |
| `LICENSE` | AGPL-3.0-or-later. |

## v1 reference

v1 is at `v1/`. It is the *current* deployed version (cococoir on
amon-sul still consumes it via `?dir=v1`). v2 replaces it incrementally.
Don't reference v1 code as "the right way" — it's the *current* way; v2
is the target. Read `v1/AGENTS.md` to understand what existed before.

## License

AGPL-3.0-or-later. See `LICENSE`. Every source file carries the matching
SPDX header.
