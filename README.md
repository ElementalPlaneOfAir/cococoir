# Cococoir

A home server in a box. NixOS + a small catalog of services,
shipped as a complete product to non-technical customers.
AGPL-3.0-or-later.

## What it is

Cococoir is a worker cooperative that builds and sells home servers
to residential customers. The product is a plug-and-play box that
replaces Google Docs, Netflix, Dropbox, and Ring with self-hosted
alternatives — no configuration, no technical knowledge required.

The core thesis: digital sovereignty is increasingly important, the
tools exist, but the setup friction excludes 95% of people. Cococoir
removes the friction by shipping pre-configured hardware with
deterministic, reproducible NixOS builds.

## Current status

- **v0 (shipped):** Go L4 TCP/UDP forwarder (`cococoir-edge` +
  `cococoir-client`), health endpoints, bbolt store, 2-VM nixosTest.
- **v2 (target):** Single-machine home server. btrfs storage,
  Jellyfin + Dex OIDC, Caddy reverse proxy with auto-TLS,
  sops-nix for secrets. `scripts/vmtest-e2e.sh` gate.
- **v3 (deferred):** Multi-tenant control plane (Postgres, web UI,
  auto-provisioning). Trigger: 10-20 customers.
- **v4 (deferred):** Cluster expansion across multiple VPSes.
  Trigger: 50-100 customers.

v1 (`v1/`) is frozen legacy — features are ported to v2, not edited
in place.

## Tech stack

| Layer | Technology | Why |
|---|---|---|
| OS & config | NixOS + flake-parts | Deterministic, reproducible, native performance |
| Storage | btrfs RAID1 pool + subvolumes | Drive add/remove anytime, per-service quotas, restic backups (planned) |
| Reverse proxy | Caddy | Auto-TLS, simple vhost config |
| Auth | Dex | OIDC provider with static password users |
| Secrets | sops-nix (age encryption) | Encrypted in repo, decrypted at activation |
| Networking | WireGuard + Go forwarder | Per-customer IPv4 routing (v3+, not v2) |
| Observability | OTEL in-process | Prober, journald tailer, embedded dashboard (planned v2) |
| Services | Jellyfin, Nextcloud, Cryptpad, qBittorrent, … | Curated catalog, not an app store |

## Design principles

- **Time to running trumps everything.** Plug in, turn on, use. No
  dashboards, no app stores, no configuration wizards.
- **Factory-enforced service contract.** Every service exposes
  `enable / domain / public` (plus service-specific options) via
  the `mkCococoirService` factory, which owns the Caddy vhost,
  systemd wiring, and btrfs subvolume declaration. See
  `nix/nixos-modules/services/_contract.nix`.
- **TLS keys never leave the box.** Caddy on the customer device
  owns TLS. The forwarding layer is L4 only.
- **Native filesystem > S3 > FUSE.** Services get real btrfs
  subvolumes as data directories. S3 is a cluster (v4) concern;
  FUSE is the last-resort fallback.
- **Nix is the source of truth.** Every machine config is a Nix
  attribute set. Never edit files on a live machine.
- **Customer-facing config under 50 lines.** Every option the customer
  must set costs us adoption. Auto-derive, default correctly, or
  eliminate the option. See `AGENTS.md` for the full rule.

## Project structure

```
cococoir/
├── nix/
│   ├── nixos-modules/         # NixOS modules (the product)
│   │   ├── cococoir.nix       #   top-level import
│   │   ├── tls.nix            #   TLS posture (acme / self-signed)
│   │   ├── base-domain.nix    #   apex domain
│   │   ├── secrets.nix        #   sops-nix secret inventory
│   │   ├── services/
│   │   │   ├── _contract.nix  #   4-option factory
│   │   │   ├── jellyfin.nix   #   Jellyfin media server
│   │   │   └── dex.nix        #   Dex OIDC provider
│   │   ├── storage/
│   │   │   └── btrfs.nix      #   btrfs pool + subvolumes
│   │   ├── edge.nix           #   Go forwarder (VPS side)
│   │   └── client.nix         #   Go forwarder (customer side)
│   ├── packages/
│   │   └── cocococoir/        # Go module (2 binaries)
│   └── tests/
│       ├── edge/              # 2-VM nixosTest (v0 gate)
│       ├── contract-conformance/  # Factory usage check
│       ├── doc-refs/          # Doc path + ADR cross-check
│       └── vmtest-wiring/     # OIDC wiring presence check
├── nixosConfigurations/
│   └── vmtest.nix             # Dev VM (all services, self-signed TLS)
├── v1/                        # Legacy codebase (frozen, read-only reference)
├── flake.nix                  # Flake entry point
├── AGENTS.md                  # Code conventions for LLM agents
├── PLAN.md                    # Technical plan (versions, ADRs, backlog)
└── BUISNESS-PLAN.md           # Customer-facing rationale + unit economics
```

## Development

```bash
nix flake check         # Run all checks (L0 go tests + L1 derivations + L2 nixosTests)
scripts/vmtest-e2e.sh   # Nuke qcow2, rebuild, boot headless, assert fresh boot (v2 gate)
nix run .#vmtest        # Boot the dev VM with all services
```

The dev VM runs at `*.vmtest.local` with a self-signed cert on port 443.
See `nixosConfigurations/vmtest.nix` for the full config.

## License

AGPL-3.0-or-later. See `LICENSE`.
