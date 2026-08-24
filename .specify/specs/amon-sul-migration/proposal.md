# amon-sul migration — first real customer box on the v2 stack

Status: proposal (not yet implemented).

Session 2026-08-23: survey + interview. Ground truth established over SSH
(192.168.0.7, hostname `amon-sul`). Decisions:

- **Strip to headless.** Remove the KDE/X11/printing/Firefox/pipewire desktop.
  The box becomes a server. brad/nicole lose their desktop — accepted.
- **Deploy via the signup flow.** amon-sul is provisioned as a customer of
  the live edge (62.238.111.21), reachable at `*.fractal.interdim.net`
  (`baseDomain = "fractal.interdim.net"`, username `fractal`, DOMAIN
  `interdim.net`). Caddy terminates real ACME certs obtained through the
  WireGuard tunnel.
- **All four custom services now** — matrix-synapse, mautrix-gmessages,
  minecraft, gdoc-extract — as *userland* NixOS modules, not factory
  services.
- **Reuse storage in place.** No 7.6T data move; services point at the
  existing `/media/entertain/*` dirs. Single-drive (`layout = "stripe"`) is
  accepted — no RAID1, no redundancy.

## Premise

amon-sul is a NixOS desktop/server hybrid running the frozen v1 storage
model (Garage + geesefs FUSE, though the FUSE layer is already dead and the
7.6T lives directly on a single 14.6T btrfs at `/media`) plus ~15 services,
of which only jellyfin and cryptpad are in the v2 catalog. Its real config
repo is gone (`/etc/nixos/limonene` dangles into an empty
`/etc/static/nixos/limonene`), so the live system is only partially
specified — the migration re-specifies the box from its running state.

Two code changes are required before the box can run the v2 stack as-is:

1. **Storage paths are hardcoded and decoupled.** Service modules declare
   absolute subvolume paths (`/data/media/movies`, `jellyfin.nix:70`) that
   ignore `cococoir.storage.btrfs.pool.mountpoint`, and the subvolume
   oneshot (`btrfs.nix:79`) fails on a target that already exists as a
   plain directory. "Point the stack at existing folders" therefore needs a
   small refactor: subvolume `mountpoint`/`quota`/`owner` become
   `lib.mkDefault`, default-derived from the pool mountpoint, and the
   oneshot tolerates an existing non-subvolume directory (skip create,
   still apply owner/mode). No new customer options — single-drive is
   already `layout = "stripe"`.

2. **The customer side of the signup flow is deferred.** The edge signs a
   customer up (allocates `/128`, generates the WG keypair, `wg set`-adds
   the peer, upserts AAAA DNS — proven by `edge-forward` L2), and the
   customer template renders `wg0` + `cococoir-client`, but with
   `peers = []`: the customer never learns its own WG IP or the edge's
   endpoint, so the tunnel cannot come up. Completing that wiring is real
   work, not "just deploy".

Deliberately out of scope for this arc:
- **Torrenting.** transmission/qbittorrent/seerr/autobrr/bazarr are dropped;
  the *arr stack (radarr/sonarr/lidarr/prowlarr) stays available but
  disabled. The "nice torrent interface" is v2.13+, deferred.
- **RAID1 / restic.** Single-drive, no offsite backup. Follow-up arcs.
- **The control plane's own customer-auth (ADR-025 order).** Unchanged here.

## Acceptance criteria

- [ ] **L1** `nix flake check` green — the storage refactor leaves the
      vmtest render byte-identical (subvolume paths, quotas, owners
      unchanged under the `/data` default), and the new `amon-sul`
      configuration evaluates (renders all enabled services + the four
      custom modules + wg0 + cococoir-client). Maps to T1, T2, T5, T6.
- [ ] **L2** `scripts/vmtest-e2e.sh` outcome is **unchanged** by the storage
      refactor (still at the jellarr P0 re-verification point — T0 records
      the baseline). Maps to T1, T2.
- [ ] **L0** `cargo test` green (no Rust change expected; guard against
      accidental drift). Maps to T8 if any crate edit lands.
- [ ] `contract-conformance` still passes and does **not** flag the four
      userland modules (they live outside `nix/nixos-modules/services/`).
      Maps to T5.
- [ ] A `nix eval` of the amon-sul config proves the jellyfin subvolume
      paths resolve to `/media/entertain/{movies,shows,music}` and the pool
      is `layout = "stripe"` with the existing device. Maps to T6.
- [ ] Manual (live box): `POST /signup` on the edge returns a hostname +
      WG keypair; the box's wg0 comes up with the edge peer; a probe from
      the edge's `/128` reaches Caddy on the box; Caddy obtains a real ACME
      cert for `jellyfin.fractal.interdim.net`. Maps to T8, T9, T10.

## Smallest version

A `nixosConfigurations/amon-sul.nix` that imports the cococoir modules, the
four userland custom modules, points storage at the existing
`/media/entertain/*` dirs (single drive, `stripe`), enables
jellyfin/cryptpad/dex, strips the desktop, and renders wg0 + cococoir-client
with a **wired** edge peer. It evaluates under `nix flake check` and the
customer-side signup wiring is proven by the `edge-forward` L2 test. The
live `nixos-rebuild` on the box is the final task, gated on the above.

## Alternatives considered

- **Migrate into real subvolumes now (snapshot/reflink the 7.6T)** — case
  for: quotas + restic-per-subvolume day one. Case against: a real data
  move on a live box for features (quota, restic) that aren't built yet,
  and the "existing plain dir" tolerance still has to be written either
  way. Rejected: reuse in place; subvolumes become a follow-up.
- **Keep the desktop (additive deploy)** — case for: non-destructive,
  smaller blast radius. Case against: the v2 product is headless, and the
  desktop config is untracked dead weight the customer has to maintain.
  Rejected: strip now (decided).
- **Deploy LAN-only with self-signed certs, sign up later** — case for:
  sidesteps the deferred customer-side WG wiring. Case against: the user
  explicitly wants `*.fractal.interdim.net` and the ACME-via-tunnel path is
  already the documented product shape. Rejected, but the WG wiring task
  (T8) is sequenced first so it is the gate for the remote half.
- **Make custom services factory services** — case for: one consistent
  contract. Case against: the factory implies Caddy vhost + Dex OIDC +
  health prober + btrfs subvolume; matrix/minecraft/gdoc-extract want none
  of that, and forcing it violates "no mechanism the customer would never
  feel". Rejected: userland modules (ADR-027).
- **Add a "secret power-user" no-redundancy toggle** — case for: explicit.
  Case against: `layout = "stripe"` already *is* the no-redundancy setting;
  a second hidden knob duplicates it and violates the 50-line rule.
  Rejected.

## Architecture decisions

- **ADR-027 (new): userland custom services.** Non-catalog services are
  plain NixOS modules the customer imports in their machine config,
  *outside* `nix/nixos-modules/services/`. They never call
  `mkCococoirService`; they compose with cococoir only through ordinary
  additive nixpkgs options (Caddy vhosts, storage mounts, secrets).
  `contract-conformance` governs the catalog only, so userland modules are
  structurally out of its scope — no special-casing.
- **Storage: derive, don't hardcode.** Subvolume `mountpoint`/`quota`/
  `owner` are declared `lib.mkDefault` by the service modules and default
  to `${pool.mountpoint}/...`; the customer overrides a `mountpoint` to
  point at an existing directory. The subvolume oneshot skips `btrfs
  subvolume create` when the path already exists as a non-subvolume, still
  applying owner/mode. Single-drive = `layout = "stripe"` (already
  supported; documented in the module description, not a new option).
- **Customer-side signup wiring.** The customer's wg0 render learns its own
  WG IP and the edge peer from the signup response (the operator pastes
  them, or they land via a rendered file) — closing the "`peers = []`"
  deferred gap. The edge's endpoint/pubkey is already served at runtime
  (`GET /pubkey`, returned in `SignupResponse`).
- **Deploy target is the flake, not tofu.** amon-sul is a real box, so it
  gets a first-class `nixosConfigurations.amon-sul` (unlike the placeholder
  `example123` which stays out of `nix flake check` for exactly this
  reason).

## Tasks

### T0: establish the gate's ground truth
**Depends on:** none
**Verification:** run `nix flake check` and `scripts/vmtest-e2e.sh`; record
the exact pass/fail set in STATUS.md (does the jellarr P0 still reproduce
clean-boot, or is it fixed?). This is the baseline every later L2 claim is
"unchanged" against.
**Files:** `docs/STATUS.md` (update the "Last e2e" line only)

### T1: storage refactor — derive subvolume defaults from the pool mountpoint
**Depends on:** T0
**Verification:** `nix flake check` green; `nix eval
.#nixosConfigurations.vmtest.config.cococoir.storage.btrfs.subvolumes`
renders the same `/data/media/...` + `/data/jellyfin/metadata` paths as
today (no drift). L1.
**Files:** `nix/nixos-modules/storage/btrfs.nix`,
`nix/nixos-modules/services/jellyfin.nix`,
`nix/nixos-modules/services/cryptpad.nix`

Subvolume `mountpoint`/`quota`/`owner` become `lib.mkDefault`, and the
service modules derive their default paths from
`config.cococoir.storage.btrfs.pool.mountpoint` instead of hardcoding
`/data`. The vmtest render must stay byte-identical.

### T2: subvolume oneshot tolerates an existing plain directory
**Depends on:** T1
**Verification:** `nix flake check` green; a vmtest-style eval where a
subvolume path is pre-created as a plain dir no longer fails the oneshot
(the create is skipped, owner/mode still applied). L1 + the existing L2
boot path.
**Files:** `nix/nixos-modules/storage/btrfs.nix`

`btrfs subvolume show` already distinguishes "is a subvolume" from "not";
when the path exists but is not a subvolume, skip `subvolume create` (and
skip the qgroup limit) and fall through to chown/chmod.

### T3: document single-drive (`stripe`) posture
**Depends on:** T1
**Verification:** module description reads clearly; no new option added.
**Files:** `nix/nixos-modules/storage/btrfs.nix`

### T4: ADR-027 — userland custom services
**Depends on:** none
**Verification:** `doc-refs` passes; the ADR is cited where the convention
is used.
**Files:** `PLAN.md`

### T5: userland modules for the four custom services
**Depends on:** T4
**Verification:** `nix flake check` green with the modules imported;
`contract-conformance` does not flag them. L1.
**Files:** `nixosConfigurations/amon-sul/custom/matrix.nix`,
`nixosConfigurations/amon-sul/custom/mautrix-gmessages.nix`,
`nixosConfigurations/amon-sul/custom/minecraft.nix`,
`nixosConfigurations/amon-sul/custom/gdoc-extract.nix`

Plain NixOS modules wrapping the nixpkgs services, ported from the live
box's running configs (extracted over SSH — matrix homeserver.yaml,
minecraft server.properties, gdoc-extract + mautrix unit files). matrix +
mautrix bring their own postgres; that is additive, no conflict with
cococoir.

### T6: amon-sul machine config + strip headless
**Depends on:** T1, T2, T5
**Verification:** `nix flake check` green; `nix eval` shows the jellyfin
subvolume paths at `/media/entertain/{movies,shows,music}`,
`layout = "stripe"`, and the desktop services (xserver, printing, firefox,
pipewire) absent. L1.
**Files:** `nixosConfigurations/amon-sul.nix`,
`nixosConfigurations/amon-sul/custom/*.nix`,
`flake.nix`

Imports the cococoir modules + the four custom modules, sets
`baseDomain = "fractal.interdim.net"`, `tls.mode = "acme"`, storage reuse
(`pool.devices = ["/dev/sda1"]`, `mountpoint = "/media"`, subvolume
overrides), dex `staticPasswords`, and removes the desktop.

### T7: sops-nix secrets wiring
**Depends on:** T6
**Verification:** `nix flake check` green; secrets inventory resolves.
**Files:** `nixosConfigurations/amon-sul.nix` (or a sibling `secrets` module)

Wire `cococoir.secrets.sopsFile` + `sops.secrets.{jellarr-api-key,
jellyfin-admin-password}` + the age key on the box.

### T8: complete the customer-side signup wiring
**Depends on:** T6
**Verification:** the customer render's wg0 has a real edge peer (pubkey +
endpoint) and the signup WG IP/private key; the `edge-forward` L2 test (or
an extended variant) proves signup → wg0-up → reachable. L1 + L2.
**Files:** `remote-infra/tofu/templates/example123.nix.tftpl`,
`remote-infra/nix/example123.nix`, `nixosConfigurations/amon-sul.nix`
(whichever holds the customer wg0 render)

The signup response already carries the customer WG keypair + edge pubkey;
the render must consume them so wg0 comes up wired, not `peers = []`.

### T9: sign up + deploy amon-sul
**Depends on:** T8, T7
**Verification:** `POST /signup` returns `fractal.interdim.net`; the box's
wg0 shows the edge peer; `curl https://jellyfin.fractal.interdim.net/health`
over the tunnel returns 200; ACME cert issued. Manual + `demo-verify.sh`.
**Files:** none (live operation; results into `docs/STATUS.md`)

### T10: nixos-rebuild on the box + verify
**Depends on:** T9
**Verification:** jellyfin/cryptpad/dex active; the four custom services
active; media visible at `/media/entertain/*`; `git diff` on the box shows
the swap from the legacy flake to the cococoir flake. Manual.
**Files:** none (live operation; results into `docs/STATUS.md`)

## Strongest objection

This deploys a system whose own gate is **red** onto a box holding 7.6T of
irreplaceable media and four live services, and it does so by *re-specifying
the box from its running state* because the original config repo is gone —
so a misremembered detail silently becomes the new source of truth. The v2
gate failing (jellarr P0) has gone unproven since 2026-08-13, and the
customer-side WG wiring we're completing in T8 is exactly the kind of
"verified by hand on a live box, broke on next boot" seam the project's
own testing protocol warns about. Defense: T0 makes the gate's state
explicit rather than assumed; the storage refactor and machine config are
pure-eval-verifiable (L1) before anything touches the box; the 7.6T is
*never moved* (reuse in place); and the live rebuild is the last task,
gated on every L1/L2 check that can run without the box. Second-order risk:
the storage refactor touches `btrfs.nix`/`jellyfin.nix` while the v2 gate is
already red — mitigated by asserting the vmtest render is *unchanged*, not
improved, and by T1/T2 being mechanical.
