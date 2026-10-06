# Fortress config store — a git-versioned magic folder (Nix flake + sops secrets) with atomic rollback

> **Amended 2026-10-02 (apply model — ADR-035).** The applier is **system-manager
> uniformly** (process-manager layer: applies fortress service closures to the
> target's systemd), NOT `nixos-rebuild` on NixOS / system-manager on non-NixOS.
> Root-system/kernel updates are a separate, independent concern the applier never
> touches. Docker is **eliminated** — two install methods: **Linux native**
> (system-manager on the host's systemd) and **macOS/Windows** (one Linux VM,
> system-manager inside). Config stays fortress-owned `config.nix` (UI has full
> authority; no NixOS coupling). See `PLAN.md` **ADR-035**.

Status: **revised** — corrects the earlier secrets model (a separate plaintext
device store was wrong: it decouples secret state from config state and defeats
atomic rollback). Unifies and supersedes the *shape* of `config-editor`
(repo-local `dashboard.nix`) and `dashboard-apply`; keeps their goal (the
dashboard edits + applies the box's config). Refines **ADR-010, ADR-013,
ADR-018, ADR-027**. Builds on the built `nix_config_parser.rs` and `claim-flow`.
Defers the exact shape of `/etc/fortress/hardware-config` (manual for now).

## Premise

**Why this, why now (the imputus is the install flow).** The product lives or
dies on making installation fluid. A Linux user should get **one magic folder** —
config + secrets — generated automatically and editable right there. A
Mac/Windows user should provision **one Linux VM** and have `/etc/fortress/config`
generated automatically inside it. On first run the folder is created and
"everything just works." Today none of that exists: install is ceremony, config
is whatever shape the machine's flake happens to be, and secrets are either
baked into the Nix store (world-readable) or hand-wired through per-secret sops
ceremony.

**The requirement that shapes the folder: reproducible, *atomically* rollbackable
config + secrets.** The whole point is to roll back the server configuration
**including secrets** with a single `git revert` and rebuild. That only works if
config and secrets are **one git-versioned unit**. This is why a separate secret
store (or plaintext secrets beside the config) is wrong — it lets secret state
drift from config state, so a revert restores config but not secrets.

**The magic folder (identical on every target — the constant):**

```
/etc/fortress/
  system_age_keys.txt             # device age key — OUTSIDE the repo, never committed
  config/                         # ← a git repo
    config.nix                    # the editor-managed app config — ONE flat file
                                  #   (services + remote-access + users)
    flake.nix                     # composes config.nix + secrets + fortress modules
    flake.lock                    # pins fortress — rolled back with the config
    secrets/secrets.enc.yaml      # sops-encrypted, COMMITTED alongside config.nix
    .git
```

The invariants that make it work:

- **Config + ciphertext are one git history.** `git revert` reverts both at once
  → rebuild decrypts the *reverted* secrets and applies the *reverted* config.
  One atomic rollback.
- **Only ciphertext is committed.** Plaintext never touches git. The device key
  (`system_age_keys.txt`, a sibling of the repo) is the only thing outside git —
  which is what makes the repo safe to push to any source.
- **Rotate without the master key:** fortress decrypts with its own device key,
  re-seals to device + owner public keys, and commits. The owner's master key
  stays offline for recovery.

**This folder is the *app*-config surface, uniform on every target — including
when fortress is a module inside an existing NixOS machine config.** The box
always owns its fortress app config (services, remote access, secrets) at
`/etc/fortress/config`, so the WebUI and `git revert` point at one known place
with zero configuration. The **machine/hardware** config (kernel, disk, users)
is a *separate layer* that lives wherever the machine's flake is (limonene's
`amon-sul.nix`, `configuration.nix`, the container image) — never in this
folder. **The folder is an app layer on every target, including the VM** — its
Linux comes from a disk image, not the folder — so there is exactly one folder
shape (the "complete system config" variant this draft once assumed is dead).
The machine flake does **not** import the folder: it imports only
`nixosModules.applier`, and the applier reads the folder at run time (ADR-035
decoupled the lifecycles; the boundary is **ADR-037**, and the trampoline that
implements it is `.specify/specs/nixos-applier-trampoline/`). The device key +
this mutable git repo both live
under `/etc/fortress/` (accepting mutable state in `/etc` for a discoverable,
uniform "magic folder" UX).

**`fortress-bootstrap` is the hero** — the shared first-run generator that
creates this folder (git repo + flake skeleton + sealed secrets + device key) on
first run, triggered per target (Linux native, the Mac/Windows VM, the install
script). Idempotent: never clobbers an existing folder.

**Cost of not building it.** Install stays ceremony. Config and secrets can't be
rolled back together, so recovery is "reinstall and re-type every secret." The
dashboard has no fixed surface to edit. The self-serve / claim-flow value never
completes because a box can't own its own reproducible config.

**Smallest version a real customer feels.** On one NixOS box (amon-sul): add the
flake + `fortress.enable = true`, first boot generates the magic folder with
sealed secrets, the box comes up "just works," and `git revert` + rebuild rolls
back config *and* secrets together. That is the moment the product promises.

**First acceptance criterion cut if forced:** the non-NixOS install flows
(Linux native / the Mac/Windows VM) and the profile default could slip a release; the
magic folder + atomic rollback cannot.

## Acceptance criteria

- [ ] **L2 — atomic rollback (headline).** Change a config field *and* a secret,
      `git revert` + rebuild, assert both roll back to the prior state (the
      service reflects the old config; the app reads the old secret). Named test
      on a box (amon-sul or vmtest).
- [ ] **L2 — bootstrap generates the magic folder.** First run creates
      `/etc/fortress/config/` (git repo + `config.nix` + `flake.nix` +
      `flake.lock` + `secrets/secrets.enc.yaml`) and
      `/etc/fortress/system_age_keys.txt`; a
      second run is idempotent (no clobber, no new key).
- [ ] **L1 — ciphertext-only in git; key outside.** Tripwire: `git ls-files` in
      the config repo contains no plaintext secret and never
      `system_age_keys.txt`; the device key path is never a store path.
- [ ] **L1 — one-line secrets.** `fortress.secrets.sopsFile` (the sealed
      `secrets.enc.yaml`) auto-wires the secret inventory + every consumer
      (`adminPasswordEnvFile`, jellarr key, jellyfin admin password) via the
      device key; no secret *value* reaches the Nix store.
- [ ] **L0/L1 — config flake.** The `/etc/fortress/config` flake evaluates with
      the flat `config.nix` composing the fortress config; `nix_config_parser`
      round-trips the `fortress.*` fields at the fixed `config.nix` path.
- [ ] **L2 — one-option install.** `fortress.enable = true` (NixOS) yields a
      working box from the generated folder; the install script and the Mac/Windows VM
      volume each do the same (expanded in the install-flow task).
- [ ] **L1 — profile.** `fortress.profile = "full" | "minimal"` (default `full`)
      drives the generated config's service set (full = all catalog services;
      minimal = dex-only); radarr/sonarr/qbittorrent default `public = false`.

## Smallest version

**T1 + T2 + T3** ship first on the NixOS target: the magic-folder contents
(config flake + device-key sops), the `fortress-bootstrap` generator, and the
**atomic rollback** proof (`git revert` + rebuild). That is the "everything just
works + I can revert" moment on the operator's real box.

Explicitly deferred (tasks T4–T8): the non-NixOS applier + install flows
(Linux native / the Mac/Windows VM), the WebUI edit/commit/revert loop, the profile
default flip (small, rides early or is extracted), and the hardware-config shape
(manual for now).

## Alternatives considered

- **Plaintext secrets in a separate device store (the earlier draft).** *For:*
  simplest, literally editable. *Against:* **decouples secret state from config
  state** — `git revert` restores config but not secrets, defeating the atomic
  rollback that is the entire point. **Rejected — this was the error.**
- **Secrets baked into the Nix store / `environment.etc`.** *For:* declarative,
  simple. *Against:* world-readable store; not editable; not rollbackable with
  config; the amon-sul `adminPasswordEnvFile` blocker. Rejected.
- **Config + sops-encrypted secrets in one git repo, device key outside.** *For:*
  atomic `git revert` of config + secrets; ciphertext-only in git (safe to push
  anywhere); rotate without the master key; reproducible. *Against:* the box is a
  stateful git writer (needs creds/conflict handling) and rollback depends on the
  applier faithfully re-reading state. **Winner** — the reproducibility gain is
  the product's promise.
- **`imports = [ /etc/fortress/config ]` (machine flake imports the folder).**
  *For:* one closure. *Against:* `nix flake update` + `git apply` + `sudo
  nixos-rebuild` ceremony; re-couples to the machine config shape. Rejected for
  the app layer.
- **The box's machine flake is the editable surface (status quo, ADR-013).**
  *Against:* no fixed auto-generated shape for the WebUI or install. Rejected as
  the editable surface; kept as the hardware/infra layer.
- **Bespoke runner supervisor (compile + restart).** *Against:* duplicates
  `nixos-rebuild` + systemd. The applier is Nix (`nixos-rebuild` on NixOS;
  system-manager on non-NixOS) — decided in T4.

**Why the winner wins:** one git-versioned unit of config + sealed secrets is the
only shape where `git revert` + rebuild gives *atomic* rollback of both, and the
device-key-outside-the-repo split keeps it pushable anywhere. That is exactly
what makes the magic folder reproducible and the install trustworthy.

## Architecture decisions

Refines four ADRs; two new ADRs needed:

- **ADR-010 (secrets in the user's repo) → refined:** the config repo holds
  *ciphertext* (`secrets/secrets.enc.yaml`) sealed to a **device key on the box**
  (`/etc/fortress/system_age_keys.txt`) + an owner key; plaintext and the device
  key are never in the repo.
- **ADR-013 (Nix-as-source-of-truth) → refined:** Nix is the source of truth, but
  the fortress-owned portion is a self-contained **git-versioned flake at
  `/etc/fortress/config/`**, so the box (and WebUI) edit a fixed, rollbackable
  surface without modeling the machine.
- **ADR-018 (config via `environment.etc`/JSON) → refined:** the *input* is the
  config flake; JSON renderings remain app-facing outputs.
- **ADR-027 (`dashboard.nix` as the editable surface) → superseded in shape:**
  the editable surface becomes the on-device git repo `/etc/fortress/config/`.
- **ADR-037 — app-vs-hardware boundary (decided 2026-10-02, written
  2026-10-06):** the fortress *app* config (services, remote access, secrets)
  lives at `/etc/fortress/config` on **every** target — Linux native, the VM,
  and when fortress is a module inside an existing NixOS machine config. The
  **machine/hardware** layer (kernel, disk, users) is separate and lives in the
  machine's own flake. The folder is an app layer on all targets — there is NO
  "complete system config" case, the VM's OS is a disk image; a machine flake's
  only fortress surface is `nixosModules.applier` + `fortress.applier.enable`, a
  boot trampoline, never the service stack. The config git repo + device key
  both live under `/etc/fortress/` (mutable state in `/etc` is accepted for a
  uniform, discoverable surface). See PLAN.md ADR-037.
- **New ADR:** the magic-folder layout + device-key seal + **atomic
  rollback** as the core invariant.
- **ADR-035 (decides the applier):** system-manager uniformly (the
  process-manager layer), NOT `nixos-rebuild` on NixOS / system-manager on
  non-NixOS; root-system/kernel updates are a separate, independent concern. Two
  install methods: Linux native + one Mac/Windows VM (Docker eliminated). The
  app-config source (`/etc/fortress/config`) is constant across both.

## Tasks

### T1: Magic-folder contents — config flake + device-key sops
**Depends on:** none
**Verification:** L1 — the `/etc/fortress/config` flake evaluates (concern
modules compose); `fortress.secrets.sopsFile` auto-wires the admin hash from the
sealed secret through the device key (no value in the store). Tripwire: no
plaintext secret / device key in `git ls-files`.
**Files:** `nix/nixos-modules/sops-wire.nix`, a config-flake template under
`nix/`, `nix/nixos-modules/secrets.nix`

### T2: `fortress-bootstrap` — generate the magic folder on first run
**Depends on:** T1
**Verification:** L2 (amon-sul/vmtest) — first boot creates
`/etc/fortress/config/` (git repo + flake + sealed secrets) +
`system_age_keys.txt`; second boot is idempotent.
**Files:** the bootstrap oneshot (new), `nix/nixos-modules/client.nix` or a
`bootstrap.nix`, `nixosConfigurations/vmtest.nix`

### T3: Atomic rollback — `git revert` + rebuild restores config AND secrets
**Depends on:** T2
**Verification:** L2 — change a config field + a secret, `git revert`, rebuild,
assert both reflect the prior state (service config + app-read secret). Named
tripwire.
**Files:** a test/script, `nix/tests/` probe

### T4: Non-NixOS applier — **DECIDED (ADR-035)**
**Depends on:** T1
**Status:** decided — the applier is system-manager, uniformly, built at run
time from the folder's own flake. Implemented at `nix/system-manager/apply.sh`;
proven by `scripts/smtest-e2e.sh`. What remains is the non-NixOS *install
target*, not the applier mechanism (T5).
**Files:** n/a (decision recorded in ADR-035)

### T5: Install flows — Linux native + Mac/Windows VM (ADR-035)
**Depends on:** T2, T4
**Verification:** L2 per target — each produces a working magic folder with no
ceremony (Linux native: one script → system-manager on the host's systemd;
Mac/Windows: one Linux VM provisioned → system-manager inside).
**Files:** `scripts/install.sh`, `nix/nixos-modules/` bootstrap trigger

### T6: WebUI edit → commit → revert loop
**Depends on:** T2, T4
**Verification:** L0 — dashboard edits `/etc/fortress/config/`, commits (and can
`git revert`); seals a generated secret to device + owner keys. L2 — edit a
service toggle in the dashboard, apply, verify; revert, verify rollback.
**Files:** `crates/client/src/dashboard/mod.rs`, `components.rs`, `nix_config_parser.rs`

### T7: Service profile (`full` / `minimal`)
**Depends on:** none (parallel; small)
**Verification:** L1 — `full` = all catalog services, `minimal` = dex-only;
radarr/sonarr/qbittorrent default `public = false`. Eval assertions on the
generated service set.
**Files:** `nix/nixos-modules/fortress.nix`,
`nix/nixos-modules/services/_contract.nix`, `nix/nixos-modules/services/{radarr,sonarr}.nix`

### T8: app-vs-hardware boundary — **DECIDED + encoded (ADR-037)**
**Depends on:** T2
**Status:** decided and written as **PLAN.md ADR-037**; encoded by
`nixosModules.applier` (the only fortress module a machine flake imports) and
proven by the trampoline spec, `.specify/specs/nixos-applier-trampoline/`. A
machine flake names no fortress service; the boundary is mechanical, not prose.
The `/etc/fortress/hardware-config/` mirror stays manual (deferred, unchanged).
**Files:** PLAN.md (ADR-037)

## Strongest objection

This design makes the box a **stateful git writer** and rests "atomic rollback"
on two things that can silently drift: (1) the applier faithfully re-reading the
reverted flake *and* re-decrypting the reverted secrets on rebuild — if the
rebuild is partial or the applier caches, `git revert` lies; and (2) a real git
history on a live box, which can fragment under concurrent edits (WebUI vs a
human vs an auto-commit), conflict, or corrupt — and if the device key is lost,
the sealed secrets are unrecoverable. Meanwhile NixOS *generations* already give
atomic closure rollback; the added value here is rolling back the **source**
(config + secrets, the thing the WebUI edits) — but the cost is a git-based
state machine on every box. For a non-technical customer, "revert with git" is
also a questionable rollback UX (the WebUI must wrap it, which is T6). If the
applier (T4) can't prove faithful re-read, the honest fallback is
`nixos-rebuild --rollback` for the closure plus a documented, manual secret
restore — and the "magic folder" still stands as the install/config surface, just
without the strong atomic-secret-rollback promise. **Mitigation:** T3 is a
named, tested tripwire for exactly the drift (config + secret must roll back
together), and T4 de-risks the applier before the WebUI loop (T6) bets on it.
