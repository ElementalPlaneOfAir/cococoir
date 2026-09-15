# Media automation stack (torrenting for customers)

## Premise

The primary customer use case for the box is "download stuff to watch on
my Jellyfin server." Today the repo ships radarr/sonarr/lidarr/prowlarr
modules, but nothing downloads (no torrent client), nothing connects
them, and the discover/search UX the customer actually wants does not
exist. The result: four unrelated admin UIs and a dead end.

The customer experience this buys: browse `seerr.<baseDomain>`, search a
movie/show, click Request — Radarr/Sonarr grab it via the torrent
client, hardlink it into the Jellyfin libraries, and it appears. One
toggle, zero wiring. Lidarr and Prowlarr are dropped (customer uses
Nicotine++ for music; indexers get configured directly in the *arrs).

Decision inputs (2026-09-14 conversation):
- **Single toggle** (STATUS Todo "single piracy toggle", ADR-004
  surface change — deliberate).
- **Full auto-wire now** (jellarr precedent: "jellyfin + jellarr" is one
  toggle; constitution §2/§4).
- **Storage = hardlinks, not moves.** The customer flagged the seeding
  vs. rename contradiction; hardlinks dissolve it (see Architecture).

If we don't build this, the box's headline use case is missing and the
existing *arr modules are decorative.

## Acceptance criteria

- [ ] `fortress.services.media.enable = true` (one customer toggle)
  renders radarr + sonarr + qbittorrent + seerr all enabled, each with
  its own Caddy vhost, all bound to 127.0.0.1, qbittorrent
  **internal-only** (`public` defaults false for it). — **L1**
  `vmtest-wiring`
- [ ] qbittorrent/sonarr/radarr users are in the `jellyfin` group and
  the download dirs exist under the media subvolumes with group write.
  — **L1** assert + **L2** e2e `stat` check
- [ ] Radarr/Sonarr import strategy is **hardlink** (no file copies on
  import; the torrent's file stays in place for seeding). — **L1**
  assert on the applier's rendered settings + **L2** wiring probe
- [ ] First boot, no manual steps beyond indexers: applier connects
  qbittorrent as the download client in both *arrs, sets root folders,
  connects seerr to Jellyfin + both *arrs. — **L0** payload-builder
  tests + **L2** e2e probes (applier unit exit 0; *arr
  `/api/v3/downloadclient` and seerr `/api/v1/settings` show the
  entries)
- [ ] Jellyfin libraries point at `<subvol>/library`, not the subvolume
  root, so raw in-flight downloads never appear in Jellyfin. — **L1**
- [ ] Seeding policy: qbittorrent categories carry max-ratio 5.0 via
  declarative `serverConfig`; cleanup removes only the qbt path. —
  **L1** assert on rendered `qBittorrent.conf` + **L2** bootstrap check
- [ ] `zramSwap.enable` on by default (memory-pressure insurance for
  low-RAM boxes). — **L1**
- [ ] lidarr + prowlarr removed from the tree (modules, dashboard
  lists, contract-conformance fixtures, bootstrap vhost list);
  `nix flake check` green. — **L1**
- [ ] Full `scripts/vmtest-e2e.sh` PASS — this run also stamps the
  pending jellarr P0. — **L2**
- [ ] **Manual step (named test):** customer adds at least one indexer
  per *arr via the UI (preset library deferred — see Strongest
  objection). Documented in the service module descriptions.

## Smallest version

One toggle → four wired services → request-to-library works for a
customer who has added an indexer. Explicitly deferred: indexer preset
library, flaresolverr (for Cloudflare-walled indexers), Lidarr/music,
per-quality-profile customization, seerr OIDC preview branch (blocked
upstream — stable Seerr has no generic OIDC; users sign in via Jellyfin
accounts and need a Jellyfin password even when Jellyfin SSO exists).

## Alternatives considered

- **Per-service toggles** (customer enables radarr, sonarr, qbt, seerr
  individually) — case for: honest about what's running. Case against:
  the wiring assertions force combinations anyway, so the extra surface
  buys only ways to build a broken half-stack; violates constitution
  §2/§3. Winner: single toggle, with the per-service enables kept for
  power users (toggle sets them with `mkDefault`).
- **Staging subvolume + copy on import** — case for: clean quota
  separation. Case against: every import is a full-file copy (slow,
  SSD-wearing on exactly the low-end hardware we budget for);
  hardlinks cannot cross subvolume boundaries, so the canonical
  hardlink pattern is impossible. Winner: downloads live **inside** the
  media subvolumes they feed.
- **Declarative config only, no applier** (customer does the API-key
  handshake dance in four UIs) — case for: no new code. Case against:
  seerr's settings live in its DB (not declarable), and the handshake
  is exactly the complexity constitution §2 says the module owns.
  Winner: small applier, jellarr precedent.
- **Drop sonarr/radarr entirely, qbittorrent + seerr only** — case
  for: two fewer services (~500MB). Case against: loses the entire
  "download all seasons / keep up to date" automation (seerr only
  requests; something must search, grab, rename, import). Winner:
  keep both.

## Architecture decisions

- Storage: **hardlink import pattern** (TRaSH-standard): per media
  subvolume gains a `downloads/` staging dir; qbittorrent categories
  write there; Sonarr/Radarr import by hardlink into
  `<subvol>/library/`. Same inode = qbittorrent keeps seeding the
  original path while the renamed library path serves Jellyfin; zero
  copies; when seeding ends, qbittorrent removes only its path and the
  library copy survives. Requires library paths inside
  `nix/nixos-modules/services/jellyfin.nix` (jellarr `virtualFolders`)
  to change from `<subvol>` to `<subvol>/library` — fresh boots only
  (amon-sul is deleted; no live library migration).
- New modules use the `_contract.nix` factory (ADR-020):
  `qbittorrent.nix` (nixpkgs `services.qbittorrent`), `seerr.nix`
  (nixpkgs `services.seerr`, own config subvolume, `requires =
  ["jellyfin"]`).
- Single toggle: new module `nix/nixos-modules/services/media.nix`
  declaring `fortress.services.media.enable`; sets the four per-service
  enables with `mkDefault`; L1 tripwire asserts the wiring (constitution
  §7, §11 — no silent seams).
- Wiring: an idempotent **bash applier** (`curl` + `jq`, via
  `writeShellScript` in `services/media.nix`) driven by pinned API
  keys: *arr keys via their `RADARR__/SONARR__SERVER__APIKEY` env
  files, qbittorrent via declarative `serverConfig` (localhost auth
  bypass — everything binds 127.0.0.1), seerr ↔ Jellyfin reuses the
  existing jellarr API key (`/var/lib/jellarr/api-key`). The applier
  is config-glue, not a service — no new workspace member (ADR-024
  governs the L4 binaries, not boot-glue; a Rust applier was started
  and torn out mid-T6 for weight). Unit orders after all four
  services' health.
- qbittorrent port forwarding: torrenting port opened in firewall
  (connectivity matters for seeding); web UI never public.
- Seeding policy: qbittorrent per-category **max-ratio 5.0** (built-in
  qbt cleanup — declarative `serverConfig`, no external janitor). When
  the goal is met, qbt removes its own path; the hardlinked library
  file survives (inode refcount — names decouple from storage).
- Memory budget: import strategy is memory-neutral; the levers are
  service reduction (T1) and `zramSwap.enable` as pressure insurance
  (low-RAM boxes).

## Tasks

### T1: Remove lidarr + prowlarr — DONE
**Depends on:** none
**Verification:** `nix flake check` green; grep for lidarr/prowlarr in
`nix/` returns nothing outside git history
**Files:** `nix/nixos-modules/fortress.nix`, `nix/tests/vmtest-wiring/default.nix`, `nix/tests/contract-conformance/default.nix`
**Reality note:** removal also touched `nixosConfigurations/vmtest.nix`,
`nixosConfigurations/dashboard.nix`, `scripts/vmtest-bootstrap.sh`
(vhost lists), `remote-infra/{nix/example123.nix, tofu/templates/example123.nix.tftpl}`,
and the dashboard `SERVICE_LIST` in
`crates/client/src/dashboard/nix_config_parser.rs` (64 client tests
green). Proof: `nix flake check` all-pass 2026-09-14.

### T2: qbittorrent service module — DONE
**Depends on:** none
**Verification:** eval + `contract-conformance` (factory conformance);
`vmtest-wiring` asserts `public` default false + jellyfin-group
membership
**Files:** `nix/nixos-modules/services/qbittorrent.nix`
**Reality notes:** (1) the nixpkgs unit's `PrivateUsers = true` maps
supplementary groups to nobody in the user namespace, silently
revoking qbt's access to the 0770 jellyfin-group media subvolumes —
the module forces it off; tripwire lands in T7. (2) qbt categories
live in `categories.json`, not `qBittorrent.conf`, so per-category
save paths are applier-created (T6 scope, amended). (3) Strays
(un-categorized downloads) land in the qbt profile dir, never inside
the media tree. Proof: extended vmtest eval (public=false, 403 vhost,
PrivateUsers=false, firewall 51413 TCP+UDP) + `status.sh` 3/3 PASS
2026-09-14.

### T3: seerr service module — DONE
**Depends on:** T2 (pattern reuse)
**Verification:** eval + `contract-conformance`; `vmtest-wiring`
asserts `requires = ["jellyfin"]` + config subvolume declared
**Files:** `nix/nixos-modules/services/seerr.nix`
**Reality note:** seerr keeps its config DB in /var/lib/seerr
(nixpkgs default; DynamicUser + StateDirectory). No btrfs subvolume —
the DB is ~MBs and /var/lib is the platform precedent for small
service state (dex, fortress-client). Proof: `status.sh` 3/3 PASS
2026-09-14.

### T4: Library paths + download dirs — DONE
**Depends on:** T2
**Verification:** `vmtest-wiring` asserts virtualFolders point at
`<subvol>/library` and downloads dirs declared; L2 `stat` on dirs
**Files:** `nix/nixos-modules/services/jellyfin.nix`, `nix/nixos-modules/services/media.nix` (dirs)
**Reality notes:** (1) dirs are a new `fortress.storage.btrfs.subvolumes.<name>.dirs`
option in `storage/btrfs.nix` (idempotent mkdir+chown+chmod on every
boot, same owner-convergence law as subvolume owners) — the media
module did not exist yet, so jellyfin.nix declares them. (2) vmtest's
jellarr virtualFolders override was deleted so the composition
exercises the module defaults. Proof: `status.sh` 3/3 PASS (incl. new
library-layout + media-dirs tripwires) 2026-09-14.

### T5: API-key pinning (config.xml) — DONE
**Depends on:** T2
**Verification:** L1 assert config.xml rendered with pinned key; L2:
`GET /api/v3/system/status` with the pinned key returns 200
**Files:** `nix/nixos-modules/services/radarr.nix`, `nix/nixos-modules/services/sonarr.nix`
**Reality notes:** the nixpkgs servarr modules don't write config.xml at
all — settings render as `RADARR__SECTION__KEY` env vars, and
`environmentFiles` takes an env file for secrets. Pinned via
`RADARR__SERVER__APIKEY`/`SONARR__SERVER__APIKEY` written by a new
shared oneshot (`services/media.nix`, keygen per jellyfin.nix:196
pattern; env files 0640 root:jellyfin). Also forced `PrivateUsers
=false` + `jellyfin` group + btrfs ordering on both arrs (the
supplementary-group seam). Proof: extended eval (environmentFiles,
groups, PrivateUsers=false, ordering, keygen enabled) + `status.sh`
3/3 PASS 2026-09-14. L2 proof of env-var auth lands with the applier.

### T6: `fortress-media-apply` applier — DONE (amended: bash, not Rust)
**Depends on:** T2, T3, T5
**Verification:** L2 applier unit exit 0 on fresh boot (the e2e asserts
the rendered config afterwards: radarr/sonarr `/api/v3/downloadclient`
lists qBittorrent; seerr settings list both *arrs). Payload-shape L0
tests were cut with the Rust crate — the e2e is the verifier for glue.
**Files:** `nix/nixos-modules/services/media.nix` (applier script +
unit)
**Amendment note (2026-09-14):** the T6 original called for a Rust
binary (ADR-024); the user challenged it mid-implementation and the
case was conceded — the applier is config-glue (a handful of
check-then-POST calls), not a service. `crates/media/` was deleted.
Scope unchanged otherwise.

### T7: Single toggle + dashboard + tripwires — DONE
**Depends on:** T2, T3, T6
**Verification:** `vmtest-wiring`: toggle → 4 enables, seerr in
dashboard, qbittorrent absent from public dashboard, hardlink setting
asserted
**Files:** `nix/nixos-modules/services/media.nix`, `nix/tests/vmtest-wiring/default.nix`, `nix/nixos-modules/fortress.nix`
**Reality notes:** the aggregate toggle needs `s ? domain` guards in
both `nix/tests/vmtest-wiring/default.nix` and
`nix/nixos-modules/network.nix` (the LAN-DNS enumeration maps `.domain`
over every enabled fortress service; the aggregate carries none).
`fortress-media-apply` orders after qbt/seerr/jellyfin conditionally.
Dashboard `SERVICE_LIST` (Rust) + fixture updated (64 tests green).
Proof: `status.sh` 3/3 PASS (incl. 9 new media-stack tripwires)
2026-09-14.

### T8: e2e + bootstrap checks, full run — DONE (2026-09-15)
**Depends on:** T1–T7
**Verification:** `scripts/vmtest-bootstrap.sh` + `vmtest-e2e.sh` PASS
(stamps jellarr P0); STATUS.md updated in same commit
**Files:** `scripts/vmtest-bootstrap.sh`, `nix/tests/` (vmtest.nix additions), `docs/STATUS.md`

**Result: E2E PASS — 41/41 checks, 0 failures** (e2e11.log, git
f2a984e): all services active, jellarr + media-apply pipelines applied,
qbt categories with correct save paths, radarr + sonarr download
clients wired, seerr connected to Jellyfin + both arrs, OIDC button
renders, TLS + DNS verified for all 7 vhosts. STATUS.md updated in
tree (uncommitted — human review before commit).

Additional failures found and fixed during the final cycle (13–16):
13. **Seerr sonarr schema requires `enableSeasonFolders`** —
    `POST /api/v1/settings/sonarr` returned 400 without it (radarr's
    schema doesn't have the field, so radarr POSTs worked). The
    silent exit-22 looked like a radarr-side failure; bash -x inside
    systemd-run exposed the exact failing request. Fixed:
    `register_seerr_service` takes per-kind extra JSON fields
    (sonarr: `{"enableSeasonFolders": false}`, radarr: `{}`).
14. **VM OOM-killed Jellyfin on the 1GiB default** — full stack needs
    ~4GiB. Fixed: `virtualisation.memorySize = 4096` in vmtest.nix
    (vmtest-only, not customer-facing).
15. **Stale qemu VM poisons e2e runs** — a leftover VM holds ports
    2222/443; every subsequent boot fails to bind and the e2e's SSH
    assertions then hit the OLD system, reporting bogus verdicts.
    Fixed: e2e script kills stale `qemu-system-x86_64.*vmtest`
    before booting (tripwire in the same commit, per the testing
    protocol).
16. Earlier in this task (from the previous session, all verified
    by the final run): seerr Jellyfin-bootstrap login design,
    `X-Emby-Token` header, `/api/v3/qualityprofile` rename, jellarr
    stop deadlock fixed via `ExecStartPre` health-gate + 60s settle,
    applier `Restart=on-failure`, probe windows 900s.

**All 8 tasks complete. Next step: `/speckit-review` in a cold window
(mandatory review class: nixos-modules + customer-facing config).**
All work is uncommitted; human review before commit.

## Strongest objection

**The toggle's promise outruns the stack's capability.** "One toggle →
working media downloads" is false for every fresh customer: with
Prowlarr dropped, *arrs know zero indexers, and public indexers that
work without flaresolverr are a shrinking, Cloudflare-walled set. A
customer who flips the toggle and adds nothing gets four green services
and zero downloads — a silent-failure seam wearing a success UX. The
mitigation (indexer presets via the applier) is deferred, and it may
turn out to be load-bearing, not optional. The honest framing is: v1
delivers a fully wired pipeline with one deliberate manual step
(indexer setup), and the follow-up proposal should ship a preset
library before this counts as "customers can actually use it."
