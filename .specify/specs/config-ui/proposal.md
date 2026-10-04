# Config UI — self-serve edit → apply → revert of the on-box fortress config

> **Amended 2026-10-02 (reality + design decision).** The original draft assumed
> the editor had to be built. It does not: the fortress-client dashboard **already
> reads, renders, and atomically saves** a single Nix config (service toggles +
> remote-access fields + users) via `nix_config_parser`. The design decision
> (this session): the editor-managed app config is **one flat file
> `/etc/fortress/config/config.nix`** (not a services/remote-access split), so it
> matches the built single-file editor and rolls back as one unit. What is
> genuinely missing — and what this arc is now about — is the **apply / revert /
> applier** half: git-committing edits, running the rebuild, surfacing the result,
> and reverting through the UI.

> **Amended 2026-10-02 (apply model — ADR-035).** The applier is **system-manager
> uniformly** (process-manager layer: applies fortress service closures to the
> target's systemd), NOT `nixos-rebuild` on NixOS / system-manager on non-NixOS —
> Apply/Revert are thin wrappers over this one applier. Root-system/kernel updates
> are a separate, independent concern the applier never touches. Docker is
> **eliminated** — two install methods: **Linux native** (system-manager on the
> host's systemd) and **macOS/Windows** (one Linux VM, system-manager inside).
> Config stays fortress-owned `config.nix` (UI has full authority; no NixOS
> coupling). See `PLAN.md` **ADR-035**.

## Premise

**Why this, why now.** `onbox-config-secrets` fixed the config *format*: a
git-versioned flat `config.nix` + sealed secrets at `/etc/fortress/config/`. The
dashboard's editor already lets a non-technical customer flip services and edit
exposure **and saves the file atomically**. But saving is not *applying* — nothing
commits to git, runs the rebuild, or tells the customer whether the change took
effect, and there is no revert. Until Apply/Revert work, a customer can edit the
file but not run the box; the "everything just works" story dead-ends at a save
that does nothing visible.

**Cost of not building it.** The editor is a save-only front end: a customer
toggles Jellyfin on, sees "saved", and nothing happens until a human runs a
rebuild by hand. Revert is pure terminal `git`. The self-serve payoff — flip a
switch, the box reconfigures — does not exist.

**Smallest version a real customer feels.** On the existing editor page, "Save &
apply" rewrites `config.nix`, commits, rebuilds, and reports the outcome (the
service actually flips). "Revert" undoes the last change and re-applies. The
customer turns Jellyfin on, hits one button, and Jellyfin comes up.

**First criterion cut if forced:** the multi-step revert-history browser (a
one-step undo suffices) and the profile selector.

## Acceptance criteria

- [x] **L0 — lossless round-trip.** `nix_config_parser` reads/writes the editor's
      fields and re-renders without corrupting unrelated Nix. *(T1 done:
      `ui_edits_round_trip_on_split_concern_modules`, 28/28 parser tests green.)*
- [ ] **L1 — schema-constrained writes (tripwire).** The editor emits only
      `ConfigSchema`-known fields; a tripwire fails if a save would free-hand or
      drop Nix the parser does not understand.
- [ ] **L2 — edit → apply flips the service.** Toggle a service, Save & apply,
      assert the rebuild actually flipped it (service active / gone).
- [ ] **L2 — revert restores (atomic rollback through the UI).** Revert undoes the
      last change + re-applies; the service flips back (config + sealed secrets
      roll back together via the folder's git history).
- [ ] **L2 — apply surfaces its result.** Save & apply reports the rebuild's
      success/failure to the user; never a silent no-op on a failed rebuild.
- [ ] **L1 — apply is the real applier.** Apply/Revert are wired to the platform
      applier the applier spike proves — not a stub. Tripwire on the wiring.

## Smallest version

The existing editor page gains **Save & apply** (rewrite `config.nix` + `git
commit` + rebuild + surface result) and one-step **Revert** (`git revert` +
re-apply). The applier is proven on one path first — the appliance / NixOS
`nixos-rebuild` against the machine that imports `/etc/fortress/config`. Deferred:
secrets editing (highest-consequence), a revert-history browser, the
`full`/`minimal` profile selector, and a polished non-NixOS (system-manager)
applier beyond the spike.

## Config shape (decided 2026-10-02)

```
/etc/fortress/
  system_age_keys.txt              # device age key — OUTSIDE the repo, never committed
  config/                          # ← a git repo
    config.nix                     # the editor-managed app config (services +
                                   #   remote-access fields + users) — one flat file
    flake.nix                      # composes config.nix + secrets + fortress modules
    flake.lock                     # pins fortress — rolled back with the config
    secrets/secrets.enc.yaml       # sops-encrypted, COMMITTED alongside config.nix
    .git
```

The editor edits **one file** (`config.nix`), matching the built single-file
editor and giving one atomic rollback unit. `flake.lock` is committed so
`git revert` rolls back the fortress version together with the config + secrets.

## Alternatives considered

- **A raw Nix editor (textarea).** *Against:* a non-technical user corrupts Nix.
  Rejected.
- **Constrained-schema form UI (the winner, already built).** The parser
  round-trips only fields it understands, so a save can never emit free-hand Nix.
- **Split concern modules (services.nix + remote_access.nix) with a multi-file
  editor.** *For:* concern separation, finer diffs. *Against:* rewrites the
  built single-file editor for multi-file; more complex save/rollback. Rejected in
  favor of the flat `config.nix` (this session's decision).
- **Separate config-editor service vs. extending the fortress-client dashboard.**
  Extend (the winner): one dashboard, one login, DRY, parser already there.
- **A bespoke rebuild script vs. the platform applier** (`nixos-rebuild` /
  system-manager). Platform applier (the winner): don't reimplement what NixOS /
  system-manager already provide.

## Architecture decisions

- **ADR-027 (dashboard as the editable surface) → realized:** the fortress-client
  dashboard edits `/etc/fortress/config/config.nix` through `nix_config_parser` +
  git, and triggers the applier.
- **ADR-013 / ADR-018 (Nix as source of truth) → applied:** `config.nix` is the
  truth; the dashboard is a view+editor over it, not a parallel store.
- **New — flat editor-managed config (decided 2026-10-02):** one
  `/etc/fortress/config/config.nix` holds every editor-managed field (services,
  remote-access, users). Matches the built single-file editor; one rollback unit.
- **New — the schema round-trip guarantee:** the editor writes only
  `ConfigSchema`-known fields; the round-trip is lossless on untouched Nix (the
  safety boundary behind a web editor over Nix). Proven (T1).
- **Shared with `onbox-config-secrets` — the applier (ADR-035):** system-manager
  uniformly (the process-manager layer), NOT `nixos-rebuild` on NixOS /
  system-manager on non-NixOS. Apply/Revert are thin wrappers over this; it is
  the load-bearing piece and is de-risked here (T5).

## Tasks

### T1: Schema round-trip coverage (foundation) — **DONE 2026-10-02**
**Verification:** L0 — `ui_edits_round_trip_on_split_concern_modules` proves a
service toggle + a remote-access field round-trip losslessly; 28/28 parser tests
green. (The parser already covered this generically; the test pins the editor's
exact surface.)
**Files:** `crates/client/src/dashboard/nix_config_parser.rs`

### T2: Point the built editor at the flat `config.nix` magic folder
**Depends on:** T1
**Verification:** L1 — `ConfigPath` resolves to `/etc/fortress/config/config.nix`
(FORTRESS_CONFIG_PATH) and `FortressConfig`'s fields (services + remote-access +
users) all live in that one flat file; a tripwire asserts the editor's writes are
schema-constrained. The editor UI itself is already built — this wires it to the
flat on-box shape.
**Files:** `crates/client/src/dashboard/mod.rs`, `nixosConfigurations/` (config.nix shape)

### T3: Save & apply (git commit + rebuild + surface result)
**Depends on:** T2, T5
**Verification:** L2 — Save & apply rewrites `config.nix`, `git commit`s, invokes
the proven applier, and surfaces the rebuild result (success/failure). Edit→apply
flips a service (VM test). Tripwire: Apply is wired to the real applier, not a
stub. (The atomic *save* already exists; this adds commit + apply + result.)
**Files:** `crates/client/src/dashboard/mod.rs`, `nix/nixos-modules/client.nix`

### T4: One-step revert (atomic rollback from the UI)
**Depends on:** T3
**Verification:** L2 — Revert does `git revert` (one step) + re-applies; the
service flips back; config + sealed secrets roll back together.
**Files:** `crates/client/src/dashboard/mod.rs`, `nix/tests/` (revert probe)

### T5: The applier (spike → decide) — load-bearing
**Depends on:** none (parallel; de-risks T3/T4)
**Verification:** prove the config applies + rolls back on the target via
`nixos-rebuild` (appliance/NixOS) and report the non-NixOS (system-manager) shape.
The "works" claim is a rebuild that flips a service and a revert that flips it
back.
**Files:** `nix/nixos-modules/` (rebuild/activation unit), `scripts/` (apply helper)

## Strongest objection

The UI's two load-bearing buttons — **Apply** and **Revert** — are exactly the
`onbox-config-secrets` strongest objection wearing a web face: they only tell the
truth if the applier faithfully re-reads the reverted config *and* re-decrypts the
reverted secrets on rebuild. A UI that reports "applied" over a rebuild that
silently didn't (cached, partial, or a git history that fragmented under a
concurrent human edit) is worse than no UI — it converts a config problem into a
trust problem, and the customer cannot see the git state the UI races against.
Building Apply/Revert before T5 proves apply+rollback is building the surface on
sand. **Mitigation:** sequence T5 (applier proof) before T3/T4 land; make "apply
surfaces its result" a hard criterion (no silent no-op); keep the write surface the
constrained schema. If T5 cannot prove faithful rollback, the honest fallback is
the editor as a *save-to-git* front end (commit only) with apply/revert left as
documented `nixos-rebuild`/`git` steps — still useful, but do not claim "Save &
apply" until the applier earns it.
