# NixOS applier trampoline — the one-line machine flake, and the app-vs-hardware boundary

Status: **proposal (not yet implemented).**
Session 2026-10-06. Ground truth: ADR-035 + ADR-036 (PLAN.md), `nix/system-manager/apply.sh`,
`scripts/fortress-bootstrap.sh`, `nix/nixos-modules/fortress.nix`, limonene's `amon-sul.nix`.

## Premise

**Why this, why now.** ADR-035 decided the applier (system-manager, built from the magic
folder's own flake) and it works — `smtest-e2e` proves `fortress-apply` installs the unit tree
and starts `fortress.target`. But nothing on a NixOS host **runs** it. `fortress-apply` installs
units into `/run/systemd/system`, which is tmpfs, and no unit in `nix/nixos-modules/` installs the
applier or calls it. So on a real NixOS box, **fortress evaporates on the first reboot** — there is
no trampoline. `fortress-bootstrap` is unrun on that path too. The install story is therefore
blocked on this mechanism, not on secrets or on the applier itself.

**This is also the missing boundary ADR.** `onbox-config-secrets` (line 185) promised a "uniform
app-config surface" ADR; PLAN.md never got one, and that spec's T4/T8 text ("the machine flake
composes this app layer", "the VM's config is a complete system config") is stale — ADR-035
killed both. The real rule, unspoken until now, is: **the machine flake never imports the
folder; the applier reads it at runtime.** The folder is an app layer on *every* target,
including the VM (whose Linux comes from its disk image, not the folder). One shape, not two.

**What happens if we don't build it.** No NixOS box can run the architecture ADR-035 chose; every
one of them loses fortress on reboot. amon-sul stays frozen in the rejected world
(`fortress.services.*` as a NixOS module), where cryptpad/forgejo are silent no-ops and the
dashboard cannot own the config surface. The one-line install target has no implementation.

**Smallest version a customer feels.** amon-sul's machine flake shrinks to hardware plus one
fortress line; the box boots, generates its own magic folder, applies it, and **survives a
reboot** with fortress back up and no human touching anything.

**Cut first if forced:** the amon-sul migration itself (T7) — the mechanism is provable on vmtest
without a real box.

## Acceptance criteria

- [ ] **L1 — the boundary is encoded.** Importing `nixosModules.applier` into a NixOS system
      yields the applier bootstrap+apply units and **no** `fortress.services.*`/`services.<svc>`
      surface. The full service stack (`nixosModules.default`) is not imported by a machine flake.
- [ ] **L1 — the trampoline is present and ordered.** The rendered config contains
      `fortress-bootstrap.service` (`ConditionPathExists=!/etc/fortress/config/flake.nix`,
      before apply) and `fortress-apply.service` (`wantedBy`/`before = multi-user.target`,
      `Type=oneshot`), each with an `ExecStart`.
- [ ] **L1 — reboot durability is structural.** `apply.sh` roots its store build under a
      persistent gcroots link, so an offline reboot after `nix-collect-garbage` still finds the
      units. (vmtest's reboot proof does not catch this — it needs its own assertion.)
- [ ] **L2 — reboot survival (headline).** vmtest with the trampoline enabled: boot → assert
      `fortress.target` + its services active → `reboot` → assert they are active again with no
      manual apply.
- [ ] **L2 — first boot generates then applies.** With `/etc/fortress` absent, first boot creates
      the folder (device key, git repo, flake, sealed secrets) and then applies it; a second
      boot changes nothing (idempotent).
- [ ] **L2 — amon-sul comes up on the new architecture.** The box's machine flake carries the
      one fortress line; after `nixos-rebuild switch` the box serves its configured services, and
      `fortress.services.*` no longer exists in its machine config.

## Smallest version

T1 + T2 + T3 + T5 + T6: the boundary ADR, the `nixosModules.applier` module, the GC-root fix, the
L1 tripwire, and the vmtest reboot proof. T4 (password surfacing polish) rides early. T7
(amon-sul) is its own step, after the mechanism is proven.

## Alternatives considered

- **Keep applying manually / via a timer.** *For:* smallest. *Against:* units live in tmpfs;
  without a boot-time apply fortress is down until a human acts. Rejected — that is not a server.
- **Install units into `/etc/systemd/system` so they persist.** *For:* no trampoline needed.
  *Against:* NixOS `/etc/systemd/system` is a read-only store symlink; the applier already
  documents that its activator fails there ("Read-only file system"). Rejected by ADR-035's
  mechanics.
- **Run apply from a `nixos-rebuild` activation script.** *For:* output visible at switch; no
  boot unit. *Against:* re-couples fortress to `nixos-rebuild`, which ADR-035 rejected; and
  activation still runs on boot, so it is a trampoline anyway — just a less honest one. Rejected.
- **Make the machine flake import the folder (`imports = [ /etc/fortress/config ]`).** *For:*
  one closure, config in the machine's graph. *Against:* mutable path read by a pure eval;
  re-couples to the machine config shape; killed in `onbox-config-secrets`. Rejected.
- **Re-expose `nixosModules.default` (the service stack) on the machine flake.** *For:*
  familiar. *Against:* that is exactly the rejected `services.fortress.*` world; it re-couples
  the app layer to the OS closure. Rejected — the machine imports `nixosModules.applier` only.

**Why the winner wins:** a boot-time oneshot that installs, then applies, from the folder is the
only shape where the applier's runtime-decoupled model survives a reboot, and importing only
`nixosModules.applier` makes the app-vs-hardware boundary mechanical rather than aspirational.

## Architecture decisions

- **New ADR — app-vs-hardware boundary (fills the gap `onbox-config-secrets` promised).** A
  fortress process, or a config a fortress process reads → `/etc/fortress/config` (app layer,
  uniform on every target, VM included). Kernel / disk / boot / users / host network →
  the machine's own flake, never the folder. The machine flake's *only* fortress surface is
  `nixosModules.applier` + `fortress.applier.enable`; it is a boot trampoline, **not** a config
  surface. The folder is an app layer everywhere — the "complete system config" shape is dead.
- **Refines ADR-035** (supplies the trampoline its "two lifecycles" implies) and **ADR-036**
  (the machine flake owns `users.users.*`; fortress services own none of it).
- **Supersedes the deployment half of `amon-sul-migration`** (Aug 23), whose T10 is
  `nixos-rebuild` — pre-ADR-035. Its ground-truth survey survives; its deploy mechanics do not.

## Tasks

### T1: Write the boundary ADR and reconcile the stale specs
**Depends on:** none
**Verification:** L1 — `scripts/status.sh` `doc-refs` stays green; the new ADR resolves (no
undecidable ADR); grep confirms the stale "machine flake composes the app layer" / "complete
system config" / `nixos-rebuild` lines are gone. (There is **no** automated spec-drift gate in
the repo — the rot these lines represent was found by hand, and building such a gate is its own
arc.)
**Files:** `PLAN.md`, `.specify/specs/onbox-config-secrets/proposal.md`,
`.specify/specs/amon-sul-migration/proposal.md`

### T2: `nixosModules.applier` — the trampoline, and only the trampoline
**Depends on:** none
**Verification:** L1 — evaluating a NixOS system that imports `nixosModules.applier` +
`fortress.applier.enable = true` renders the two units with `ExecStart`, the bootstrap
`ConditionPathExists`, and correct ordering; it renders **no** `fortress.services.*`.
**Files:** `nix/nixos-modules/applier.nix` (new), `flake.nix`, a `fortress-bootstrap` package
under `nix/packages/` (mirrors `nix/system-manager/apply.nix`).

### T3: Root the applier build so the unit tree survives GC
**Depends on:** none
**Verification:** L1 — `apply.sh` passes a persistent `-o /nix/var/nix/gcroots/...` (asserted,
because vmtest's reboot does not exercise GC). **Scope:** this roots the *output* only; the
folder's flake source and inputs are not rooted, so an offline reboot works on a default box
(`nix.gc.automatic = false`) but not after a GC. Accepted (option 2); see ADR-037.
**Files:** `nix/system-manager/apply.sh`, `nix/tests/default.nix`

### T4: Surface the first-boot admin password on the NixOS path
**Depends on:** T2
**Verification:** L2 — first boot writes the password to the journal **and** broadcasts it once
(`wall`), because a systemd oneshot's stdout is not shown live by `nixos-rebuild switch`; a
second boot prints nothing.
**Files:** `scripts/fortress-bootstrap.sh`, `nix/nixos-modules/applier.nix`

### T5: L1 tripwire for the trampoline and the boundary
**Depends on:** T2
**Verification:** L1 — `nix/tests/default.nix` asserts the applier module renders the units, the
machine-flake module exposes no service surface, and `apply.sh` roots its build.
**Files:** `nix/tests/default.nix`, `scripts/status.sh`

### T6: L2 reboot-survival proof
**Depends on:** T2, T3
**Verification:** L2 — `scripts/smtest-e2e.sh` (the ADR-035 runtime VM): dogfood the trampoline,
boot, assert fortress up, `reboot`, assert fortress up again with no manual apply; plus an on-box
`fortress-bootstrap` run (layout + idempotency). **Both pass 6/6.**
**Files:** `nixosConfigurations/smtest.nix`, `scripts/smtest-e2e.sh`

### T7: Migrate amon-sul to the one-line machine flake
**Depends on:** T6
**Verification:** L2 — the box serves its configured services after `switch`; its machine config
carries hardware + one fortress line; `fortress.services.*` and `services.dex.settings.*` are gone
from it and live in `/etc/fortress/config/config.nix`.
**Files:** limonene `modules/systems/amon-sul.nix`, a limonene hardware module, the box's
`/etc/fortress/config/config.nix`.

## Strongest objection

The trampoline makes **every boot depend on `nix build` succeeding** — a Nix evaluator, the
folder's `flake.lock`, and the fortress flake's inputs must all be present and resolvable at boot,
as root, before `multi-user.target`. If the lock is wrong, an input is unfetchable and uncached,
or the flake fails to evaluate, the box boots *without* fortress and the failure surfaces only in
the journal — a new single point of failure replacing the old "NixOS module" robustness that at
least failed at build time. The GC-root fix (T3) covers only the collected-store case; it does
nothing for a bad lock or an offline first boot. A NixOS-native deployment currently survives a
broken config by rolling the generation back; this design has no equivalent for the app layer
except `git revert` + re-apply, which itself needs the build to work. **Mitigation:** the L2
reboot proof (T6) fails loudly if the build is not self-sufficient; the applier should surface
build failure as a *degraded* state (a clear unit-failed message), not a silent absence of
fortress. If this proves fragile in practice, the honest fallback is applying once at
switch-time and accepting that config edits need an explicit apply (T6's UI loop), keeping the
boot path as thin as possible.
