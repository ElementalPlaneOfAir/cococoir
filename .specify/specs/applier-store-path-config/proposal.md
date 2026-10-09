# Applier contract — store-path config, systemd-managed dirs

## Premise

`apply.sh` installs **only** `${units}/systemd/system` into
`/run/systemd/system` (`apply.sh:45,75`). But modules freely express
effects through other activation mechanisms:

- `environment.etc` — the `fortress-client` config (`client.nix:60`, the
  `/etc/fortress-client.json` its `ExecStart` reads).
- `systemd.tmpfiles.rules` — the OIDC client-secret dirs
  (`integrations/*-oidc.nix`: `d /etc/dex/clients …`) and every
  plain-dirs data dir (`storage/plain-dirs.nix:46`).

None of those reach reality under the applier. The nix expression *claims*
`/etc/fortress-client.json` exists; it never does; and the only symptom is
a service that dies at boot or a dashboard that 502s (the amon-sul
dashboard, 2026-10-08). That is a silent-failure seam (constitution §11).

This is **not** "nix is stateful". NixOS activation is imperative too — but
it is *complete*. The applier is a hand-rolled **partial** activation, and
the partiality is an unenforced accident. ADR-035 deliberately avoids
system-manager's real activator (it fights a NixOS host: read-only `/etc`,
OS-owned users, `/run/wrappers`), so the applier owns re-implementing
activation — and re-implemented subsets drift, silently.

**The invariant (user-directed):** a fortress config is a **store path**.
The only non-store reach is decrypting a sops secret at runtime via the
device age key at `/etc/fortress/system_age_keys.txt` (never in the store).
Then "install the units" *is* the complete activation, and every unit is
self-contained.

*If we don't build this:* every service graduated onto the applier
re-introduces the same silent seam, and the box can never serve its own
dashboard or media stack.

## Acceptance criteria

- [ ] No rendered fortress service references a non-store config path.
      L1: `applier-wiring` asserts every service `ExecStart`/`Exec*` is
      store-pathed, with one documented allowlist entry for the sops age
      key (`/etc/fortress/system_age_keys.txt`).
- [ ] `systemd.tmpfiles.rules` is empty in the applier composition.
      L1: `applier-wiring` asserts it.
- [ ] `services.fortress-client` takes the client config as a nix value and
      renders it to a store path; `ExecStart` carries `-config /nix/store/…`
      and no `/etc/`. L1 assertion + applier e2e.
- [ ] The three OIDC client-secret files live under a **systemd-managed**
      dir (StateDirectory/RuntimeDirectory), created by systemd, not
      tmpfiles. L1: no `tmpfiles`; L2: vmtest OIDC e2e still passes.
- [ ] `plain-dirs` creates its dirs via a **systemd unit** (mirroring
      `fortress-btrfs-subvolumes`, `btrfs.nix:352`), not tmpfiles.
      L1: no `tmpfiles`; L2: vmtest media e2e still passes.
- [ ] The applier host shows `fortress-client` **active** and the dashboard
      serving on the LAN plane. L2: `scripts/smtest-e2e.sh`.
- [ ] PLAN.md carries the ADR-035 amendment; STATUS.md the proof.

## Smallest version

The invariant is only real once it is enforced, and the applier assertion
fails the moment it exists — so the smallest shippable slice is **the three
migrations that are active on the amon-sul box plus the assertion**:

1. `client.nix` → store-path config (unblocks the dashboard, the actual 502).
2. `plain-dirs.nix` → systemd unit (the box runs `backend = "plain-dirs"`,
   so its `/media` dirs are currently never created).
3. The L1 assertion.

The OIDC-secret-dir migration is **deferred**: those integrations are
inactive under the applier (their services are stubs), so they do not
appear in the applier composition, and the assertion does not flag them. It
lands when the media/forgejo stack graduates.

## Alternatives considered

- **Teach `apply.sh` to materialize `environment.etc` + `tmpfiles.d`.**
  *For:* modules unchanged, one place. *Against:* re-implements
  systemd-tmpfiles, writes host `/etc` that NixOS owns (the exact conflict
  ADR-035 cites), and the supported surface stays implicit — the next
  activation mechanism repeats the bug.
- **Special-case just the client** (build its config as an ad-hoc store
  path). *For:* tiny, fixes the 502 today. *Against:* leaves the class
  unaddressed; `plain-dirs` is already broken on the same box, and the L1
  guard would still be absent.
- **Adopt system-manager's real activator.** *For:* removes the hand-rolled
  engine. *Against:* it manages `/etc` + users + wrappers and fights a NixOS
  host; this is the ADR-035 decision, not reopened here.

Why the winner wins: the store-path invariant makes the unit self-contained,
so the applier's *only* job is installing units — a surface small enough to
enforce with one assertion. It is the only option that removes the *class*,
not the instance.

## Architecture decisions

- **ADR-035 (amended):** the applier applies **units only**. A fortress
  module must express runtime inputs as store paths referenced by the unit;
  the sole non-store reach is runtime sops decryption. Config never travels
  through `environment.etc`; dirs are systemd-managed, never `tmpfiles`.
- Constitution §7/§11 (tripwire; silent seams are bugs): the L1 assertion is
  the tripwire and ships in the same commit as the migrations.

## Tasks

### T1: client config → store path
**Depends on:** none
**Verification:** L1 `applier-wiring` — `fortress-client` `ExecStart`
contains `/nix/store/` and no `/etc/`.
**Files:** `nix/nixos-modules/client.nix`

Replace the `configFile` (path, `/etc` default) with a `settings` attrset,
render to `pkgs.writeText`, pass the store path to `-config`. Keep
`adminPasswordEnvFile` (already a runtime secret path).

### T2: plain-dirs → systemd unit
**Depends on:** none
**Verification:** L1 — applier composition has empty
`systemd.tmpfiles.rules`; L2 — vmtest media e2e passes.
**Files:** `nix/nixos-modules/storage/plain-dirs.nix`

Mirror `fortress-btrfs-subvolumes`: a `fortress-plain-dirs` oneshot that
`mkdir -p` + `chown`/`chmod` on boot. Reuse `btrfs.nix`'s `dirLine` if it
factors cleanly.

### T3: L1 invariants in `applier-wiring`
**Depends on:** T1, T2
**Verification:** the new assertions fail against the pre-fix tree and pass
after.
**Files:** `nix/tests/applier-wiring/default.nix`

Assert: empty `tmpfiles`; every service `Exec*` store-pathed except the
allowlisted sops key; `fortress-client` `ExecStart` store-pathed.

### T4: docs
**Depends on:** T1–T3
**Verification:** `nix flake check` (doc-refs).
**Files:** `PLAN.md`, `docs/STATUS.md`

ADR-035 amendment; STATUS entry naming the proof.

### T5 (deferred): OIDC secret dirs → systemd-managed
Lands when the media/forgejo stack graduates onto the applier.
**Files:** `integrations/{forgejo,jellyfin,cryptpad}-oidc.nix`

## Strongest objection

**The assertion is whack-a-mole.** Banning `environment.etc` and
`tmpfiles` fixes today's two mechanisms, but the applier's real failure is
that it re-implements activation at all — a future module using
`system.activationScripts`, `users.users`, `fileSystems`, or `boot.*` would
silently break identically, and no assertion here would catch it. The
honest version of this arc is a single **enforced applier surface** (a
positive list of what the applier materializes, asserted over the rendered
composition), not a blocklist of two attributes. If this proposal ships as
a blocklist it buys the amon-sul box one working boot and leaves the class
open — which, per the premise, is the thing we are actually trying to kill.
