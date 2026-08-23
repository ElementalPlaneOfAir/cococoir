# Cococoir Rust workspace: per-system crates + per-system secrets

## Premise

**Why this, why now.** Cococoir is **two systems**, but they live in one
monolith crate `packages/cococoir`:

1. **The remote infra** — the `edge` box, which *is* the control plane:
   forwarder + control-plane API + health + DNS reconcile, one process.
   "edge" vs "controlplane" is naming, not two services (today
   `cococoir-edge` runs the control plane in-process, and a redundant
   `cococoir-controlplane` binary duplicates it).
2. **The customer box** — forwards local traffic to the edge *and*
   serves the config dashboard. Today this is split into two binaries
   (`cococoir-client` forwarder + `cococoir-dashboard` UI), but it is
   one system (the original ADR-017/024 "embedded dashboard" shape).

One `Cargo.toml` means every binary compiles the union of all deps
(sqlx + rnix + redis + hickory + x25519 + askama + poem + …) and shares
one tangled `Cargo.lock`. Secrets are inconsistent: the edge uses typed
`declare_secrets!`, the dashboard reads `COCOCOIR_ADMIN_PASSWORD_HASH`
via ad-hoc `env::var`, `REDIS_URL` is a CLI flag — and the edge's toml
already drags the operator-side `[profiles.provisioning]` into its
generated union (pollution). The secretspec-scopes arc left a
root-symlink → crate-file layout that is the *minimum* to make one crate
work; it is the wrong shape for N systems.

**What happens if we don't.** The tangle compounds. The prober, journald
tailer, and OTEL exporter all land in the customer box per ADR-017 and
would otherwise grow the monolith; the union-pollution failure mode is
already visible in the edge toml.

**What I'd cut first.** The dashboard admin-hash migration is the one
deferrable piece — the split + merge + per-crate tomls delivers the bulk
of the value; migrating a single optional secret can ride along or
defer.

**Smallest version a customer feels.** None. This is internal structure
with no customer-visible change. The payoff is maintenance: removing the
dependency tangle, collapsing the redundant edge/controlplane and
client/dashboard naming, and giving each system a typed, isolated secret
contract.

## Acceptance criteria

- [ ] Workspace at repo root: `Cargo.toml` + `Cargo.lock` at root, three
      members under `crates/` (`core`, `controlplane`, `client`).
      `cargo test` green from the root. (L0)
- [x] Binary names: `cococoir-edge` and `cococoir-client` build and are
      the only two deployed binaries. `cococoir-controlplane` is deleted
      (edge *is* the control plane); `cococoir-dashboard` is deleted
      (merged into `cococoir-client`, which now serves both the
      forwarder and the config dashboard). (L0 cargo build; L1 edge
      systemConfig builds)
- [x] The edge's secrets live in `crates/controlplane/secretspec.toml`
      (the five secrets, `[profiles.default]`) with the provisioning
      block removed — no union pollution. The client crate has no
      secretspec.toml yet (its only candidate secret, the dashboard
      admin hash, is deferred — see below). (L0 secret tests)
- [x] `cococoir-client` runs the forwarder and the dashboard in one
      process with a shared shutdown signal; a dashboard DB failure
      degrades the dashboard off without taking down the forwarder.
      (L0 cargo build; L1 vmtest-wiring)
- [ ] ~~Dashboard admin password hash resolves via `declare_secrets!`~~ —
      **deferred** to a follow-up (keeps reading
      `COCOCOIR_ADMIN_PASSWORD_HASH` env; `crates/client/secretspec.toml`
      added when it lands).
- [x] Provisioning toml is a standalone real file at repo root (no
      symlink), and `nix run .#secretspec -- export -P provisioning -S
      token` / `-S provision` resolve from it. (Manual: provision dry-run
      with a seeded store value)
- [x] `cargo test` green (145), `doc-refs` L1 green, edge systemConfig
      builds, `vmtest-wiring` + `contract-conformance` L1 green. `nix
      flake check` is green except the **two pre-existing** failures:
      `example123` placeholder (missing storage) and `edge-forward`
      (references the removed NixOS `services.cococoir-edge` module; the
      edge now runs via system-manager). (L0/L1)
- [ ] `PLAN.md` (ADR-026) + `docs/STATUS.md` updated in the same commit.

## Smallest version

Root workspace + three crates + the client/dashboard merge + per-crate
`secretspec.toml` + the provisioning toml split. The dashboard
admin-hash migration is the explicitly deferrable slice.

## Alternatives considered

- **A — root workspace + `crates/` (winner).** `Cargo.toml`/`Cargo.lock`
  at root; members under `crates/{core,controlplane,client}`; the Nix
  build wrapper at `nix/packages/cococoir/default.nix` produces one
  derivation with both binaries. For: realizes the two-system model,
  per-system dep graphs, `cargo` works from anywhere, matches the
  user's stated proposal-1 intent. Against: re-touches the same paths
  we just moved in the secretspec-scopes arc (`flake.nix`,
  `client.nix`, `doc-refs`, `process-compose`).
- **B — single crate + workspace manifest, one member.** For: minimal
  diff. Against: pure churn — no dependency isolation, no boundary to
  hang a secret contract on. Rejected.
- **C — workspace under `packages/cococoir/` (`crates/` nested).**
  For: smallest path churn (`flake.nix`, `client.nix`, `doc-refs` keep
  pointing at `packages/cococoir`). Against: workspace not at root (the
  stated intent), and the name `packages/cococoir` becomes a lie — it
  holds crates, not a crate. Rejected.
- **D — one root `secretspec.toml`, every crate
  `declare_secrets!("../secretspec.toml")` + `load_profile()`.** For:
  matches the original proposal-2 "single environment." Against:
  `declare_secrets!` generates a **union over all profiles** in its file
  (verified in `secretspec-derive-0.19.1/src/lib.rs`), so every binary's
  `SecretSpec` would carry every system's fields — renaming a dashboard
  secret becomes a compile error in the edge crate. Plus the root toml
  must be layered into the store for every crate. Rejected.
- **Winner is A**, with `extends` available as the one-line escape hatch
  when a genuinely shared secret appears (inheritance is resolved at
  compile time via `Config::try_from` → `ConfigGraphLoader`; only
  `from_str` skips it). We do **not** create an empty `shared/base`
  today — no shared secret exists yet, and an empty base is weight on
  the airplane.
- **Customer box = one binary (merge), not two.** Decided by the user:
  the forwarder and the config dashboard are one system, so
  `cococoir-client` embeds the dashboard (ADR-017/024's original shape)
  and `cococoir-dashboard` is deleted. The rejected alternative —
  keeping two processes in one crate — was smaller but preserved the
  "naming confusion" the user wants gone.

## Architecture decisions

- **ADR-026 (new): the cococoir Rust code is a cargo workspace of
  per-system crates; each secrets-consuming crate owns its
  `secretspec.toml`.** Supersedes ADR-024's "single Rust crate
  (`packages/cococoir`)" language; ADR-024's contract (binary names,
  CLI flags, config JSON, `/status` schema) is preserved for the two
  surviving binaries. Two redundant binaries are deleted
  (`cococoir-controlplane`, `cococoir-dashboard`) because each was a
  second name for an existing system.
- **Crate boundaries** (module ownership is already clean):
  - `cococoir-core` — `forwarder`, `tcp`, `udp`, `retry`, `logger`,
    `health` (the shared L4 engine). No binaries, no secrets.
  - `cococoir-controlplane` — `controlplane` module (dns, wg,
    routing_config, secret, auth); hosts `cococoir-edge` (forwarder +
    control-plane API + health + reconcile, one process). Owns
    `[profiles.edge]`.
  - `cococoir-client` — `app` (forwarder runner) + `dashboard` module
    (auth, components, db, nix_config_parser); hosts the single merged
    `cococoir-client` binary. Owns `[profiles.dashboard]`.
- **The merge:** one tokio runtime, the forwarder and the dashboard
  server as concurrent tasks, one shared shutdown signal. `app::run`'s
  blocking shape and `dashboard_entry` are refactored into a single
  `main` (this is the one non-mechanical task — see T3).
- **Binary naming:** the merged customer-box binary keeps the deployed
  name `cococoir-client` (systemd unit, `example123.nix`, L2 test all
  reference it). If "dashboard" should be the canonical name instead,
  that is a one-line rename in a follow-up — flagged, not decided here.
- **Secrets:** the edge profile stays `[profiles.default]` (deferred
  `default`→`edge` rename — only one profile, no peers yet, and the
  rename would churn `load()` → `load_profile()`). `REDIS_URL` is **not**
  migrated — it is a CLI flag (`--redis-url`), not a secret. The
  dashboard `ADMIN_PASSWORD_HASH` migration is **deferred** (keeps
  reading `COCOCOIR_ADMIN_PASSWORD_HASH` env; the "no hash → Dev auth
  mode" behavior is unchanged). Provisioning secrets (`HETZNER_TOKEN`,
  `ADMIN_KEY`) move to the standalone root toml that no crate extends,
  keeping project name `cococoir-edge` so the file-store path
  (`remote-infra/.secrets/cococoir-edge/provisioning/`) is unchanged.
- **Nix:** one derivation builds the workspace (crane `src` = workspace
  root; `cargoLock = ./Cargo.lock`). `cleanCargoSource` drops
  `secretspec.toml` (unknown extension) as it does today, so the filter
  keeps `**/secretspec.toml` and layers it into the store. Binaries are
  named `cococoir-*` in `src/bin/` so the `postInstall` renames go away.

## Tasks

### T1: Workspace scaffold + `cococoir-core`
**Depends on:** none
**Verification:** `cargo test -p cocococoir-core` green.
**Files:** root `Cargo.toml`/`Cargo.lock`, `crates/core/Cargo.toml`,
`crates/core/src/{lib,forwarder,tcp,udp,retry,logger,health}.rs`
- Move the shared engine out of `packages/cococoir/src` into
  `crates/core` and assign the core-only deps.

### T2: `cococoir-controlplane` + `[profiles.default]`
**Depends on:** T1
**Verification:** `cargo test -p cocococoir-controlplane` green;
`secret::tests::*` resolve the five edge secrets from a scratch toml;
`cococoir-edge` builds.
**Files:** `crates/controlplane/Cargo.toml`,
`crates/controlplane/src/{lib,controlplane/**}.rs`,
`crates/controlplane/src/bin/cococoir-edge.rs`,
`crates/controlplane/secretspec.toml`
- Move the `controlplane` module; write `secretspec.toml` with the five
  secrets only (no provisioning block; profile stays `default`);
  delete `controlplane.rs` + `controlplane_entry` (redundant — edge is
  the control plane).

### T3: `cococoir-client` — merge forwarder + dashboard
**Depends on:** T1
**Verification:** `cargo test -p cocococoir-client` green; one binary
serves both `/status` (forwarder) and the dashboard routes; a dashboard
DB failure degrades the dashboard off without killing the forwarder.
**Files:** `crates/client/Cargo.toml`,
`crates/client/src/{lib,app,dashboard/**}.rs`,
`crates/client/src/bin/cococoir-client.rs`
- Move `app` + `dashboard`; refactor `app::run` (blocking) and
  `dashboard_entry` into one entry with a shared shutdown signal;
  delete the `cococoir-dashboard` bin. Dashboard admin-hash secretspec
  migration **deferred** (keep `AuthMode::from_env`).

### T4: Nix build over the workspace
**Depends on:** T1, T2, T3
**Verification:** `nix build .#systemConfigs.edge` exits 0; `doc-refs`,
`forwarder-unit-tests`, `vmtest-wiring`, and `contract-conformance` L1/L0
checks green; the dashboard dev flow runs against the merged binary.
(`edge-forward` and `example123` fail for pre-existing reasons unrelated
to this arc.)
**Files:** `nix/packages/cococoir/default.nix`, `flake.nix`,
`nix/nixos-modules/client.nix`, `nix/dev/process-compose.nix`,
`nix/tests/doc-refs/default.nix`, `nix/tests/default.nix`
- Move the derivation to `nix/packages/cococoir/default.nix` (workspace
  src + `**/secretspec.toml` filter, root `cargoLock`); repoint
  `flake.nix:92`/`:95`, `client.nix`, `doc-refs` `moduleFiles`,
  `nix/tests/default.nix`'s `cococoirPkg` call site, and
  `process-compose.nix`'s `cd` + `COCOCOIR_CONFIG_PATH`; drop the stale
  Go-era comments in `client.nix`/`nix/tests/default.nix`; give the
  client systemd unit a writable dashboard DB path (`StateDirectory` +
  `XDG_DATA_HOME`).

### T5: Provisioning toml split
**Depends on:** T2
**Verification:** `nix run .#secretspec -- export -P provisioning -S
token` and `-S provision` resolve from the root file; `provision-edge.sh`
dry-run reaches the export steps.
**Files:** `secretspec.toml` (root real file),
`remote-infra/scripts/provision-edge.sh`
- Delete the crate-local `[profiles.provisioning]`/`[scopes.*]`/provider
  block; write the standalone provisioning toml at repo root (no
  symlink) keeping project name `cococoir-edge` (preserves the file-store
  path); keep the `-f ./secretspec.toml` anchor.

### T6: Verify + docs
**Depends on:** T4, T5
**Verification:** `cargo test` (all members) green; `doc-refs`,
`forwarder-unit-tests`, `vmtest-wiring`, `contract-conformance` green;
`tofu validate` green.
**Files:** `PLAN.md` (ADR-026), `docs/STATUS.md`
- Add ADR-026, update the ADR-024 language + every `packages/cococoir`
  path reference, and refresh STATUS.md (move the secretspec-scopes
  entry's "real file in crate" framing to the new per-crate layout).

## Strongest objection

The split is mechanical, but **the merge is not**: refactoring
`app::run` (a blocking forwarder loop) and `dashboard_entry` (a blocking
poem server) into one process is runtime lifecycle work with real
failure modes — port conflicts, a dashboard crash taking down the
forwarder (or vice versa), a shutdown signal that half-tears-down. That
risk is the reason the merge was originally deferred to "v2 work" in
ADR-017, and it expands this arc well past a structural refactor. The
rest is customer-invisible re-churn of paths we just moved, and the only
genuine secret-migration payoff is one optional dashboard field
(`REDIS_URL` is a flag, not a secret). The counterweight: doing the
split without the merge would enshrine the client/dashboard naming
confusion we are trying to kill, and every later system (prober,
journald tailer, OTEL) would either grow a three-way monolith or force a
second, larger restructure. If the merge proves too risky mid-arc, the
honest fallback is to land the workspace + per-crate secrets with two
customer-box binaries and re-raise the merge as its own proposal — but
that must be a conscious choice, not a silent scope cut.
