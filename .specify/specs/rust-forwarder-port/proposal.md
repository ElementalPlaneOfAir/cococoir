# Rust forwarder port — calibration arc

Status: proposal (not yet implemented).

## Premise

The whole Go role (forwarder, edge/client mains, health, logger) moves to
Rust — but this arc ports **only the forwarder + mains + health + logger**
first, as a calibration experiment. The forwarder is the only Go code with a
test oracle (572-line `forwarder_test.go` + the 2-VM `edge-forward`
nixosTest), so it is the cheapest possible measure of Rust port velocity
under our LLM-driven workflow. If the port lands clean, the greenfield
(prober, journald, dashboard, config agent) proceeds in Rust with evidence.
If it drags, we learned at 2.3k lines instead of 20k.

Why now: nothing is deployed, and `internal/store` is orphaned dead code that
deserves deletion (zero-debt policy, ADR-017's "spine" is already partial).
The forwarder is dormant v0 B2B infra — zero customer risk — so this arc
cannot delay any customer-facing milestone.

This is the calibration half of `writing/llm/rust-rewrite.md`. The greenfield
half is explicitly **out of scope** and gated on this arc's result.

## Acceptance criteria

- [ ] L0: `cargo test` (Rust unit/integration tests) passes; it replaces
      `go test ./...` as the `forwarder-unit-tests` check's body.
      Maps to T3, T5.
- [ ] L2: `edge-forward` nixosTest (2-VM, edge↔client over WireGuard)
      passes against the Rust binaries — same data path, same `/status`
      JSON contract. Maps to T7.
- [ ] L1: `nix flake check` passes (doc-refs, contract-conformance,
      vmtest-wiring untouched and green). Maps to T8.
- [ ] Config schema (`{forwards:[{listen_addr,proto,dest_addr}]}`), CLI
      flags (`-config`, `-log-format`, `-health-addr`), and binary names
      (`cococoir-edge`, `cococoir-client`) unchanged. Maps to T6.
- [ ] Go module and `internal/store` deleted; no `.go` files remain under
      `nix/packages/cococoir/`. Maps to T8.
- [ ] Calibration measured: time spent on the port recorded in the proposal
      for the greenfield decision. Maps to T9.

## Smallest version

A working Rust forwarder + health server + two mains that pass L0 and L2,
replacing the Go module, with Go deleted in the same commit. Nothing else.

## Alternatives considered

- **Keep Go** — case for: zero cost, forwarder is dormant, Go is fine for
  this. Case against: the plan locks Rust for the whole role; the greenfield
  config agent/dashboard will be Rust; a deferred port just grows. Rejected
  as the settled direction (rust-rewrite.md).
- **std::net + threads instead of tokio** — case for: zero deps, honors the
  no-bloat rule. Case against: the Go code is async-shaped (`ctx` +
  `select`, goroutine-per-conn); a std-thread translation of the cancelable
  retry sleep is more code for a worse shape, and it calibrates the wrong
  stack. Rejected.
- **tokio + axum + serde** — case for: 1:1 shape match to the Go
  concurrency model, most-maintained crates in the ecosystem, measures the
  stack the greenfield will actually use. Winner.
- **Port `internal/store` to Rust** — case for: keeps bbolt. Case against:
  it has no consumers (neither binary links it); PLAN.md points the v3
  control plane at Postgres. It's dead code — delete it, don't port it.
  Rejected (user-confirmed).
- **Full rewrite in one arc including greenfield** — case for: "no islands."
  Case against: that's not a calibration, it's a leap; the greenfield has no
  oracle and deserves its own proposal gated on this arc's velocity. Deferred
  by design.

## Architecture decisions

- New ADR (supersedes ADR-017's "Go service is the spine"): the cococoir
  service is Rust. The bounded-scope statement survives; only the language
  changes. Recorded in PLAN.md.
- No other ADR changes. The two-trust-domain split, the in-process collector,
  and the HTMX dashboard remain design intent, not this arc's work.

## Tasks

### T1: Rust workspace skeleton + config/validation model
**Depends on:** none
**Verification:** `cargo test` compiles; `New` rejects empty forwards,
unknown proto, missing fields (port of `TestNew_*`). L0.
**Files:** `nix/packages/cococoir/Cargo.toml`,
`nix/packages/cococoir/src/lib.rs`,
`nix/packages/cococoir/src/forwarder.rs`

### T2: retry-with-backoff bind (tcp + udp paths)
**Depends on:** T1
**Verification:** unit tests port `TestIsTransientBindErr`,
`TestNextBackoff`; cancel-during-sleep honored via `tokio::select!`. L0.
**Files:** `nix/packages/cococoir/src/forwarder.rs`,
`nix/packages/cococoir/src/retry.rs`

### T3: TCP + UDP serving, stats, graceful drain
**Depends on:** T2
**Verification:** ports `TestRun_TCPForward`, `TestRun_UDPForward`,
`TestRun_GracefulShutdownNoInflight`, `TestStats_*` (bound/bind-error,
conn/flow counts, slice-is-copy). L0.
**Files:** `nix/packages/cococoir/src/forwarder.rs`,
`nix/packages/cococoir/src/tcp.rs`,
`nix/packages/cococoir/src/udp.rs`

**Architectural amendments made during implementation (not blind
Go copies):**
- **UDP shutdown is now clean.** Go's `relayUDPResponses` and
  `expireIdleFlows` goroutines never terminate, so Go's graceful
  drain *always* times out for UDP forwards. Here every task
  (read loop, relay, accept loop) selects on the shutdown signal and
  returns; drain completes in bounded time. L2 oracle unaffected.
- **Per-flow idle timers replace the global ticker.** Go keeps one
  shared `flows` map mutated by the read loop, a relay goroutine,
  and a separate `expireIdleFlows` goroutine. Here each relay task
  owns its flow's lifetime via a `sleep(idle_remaining)` deadline
  and removes its own map entry on exit — no shared-ticker
  coordination. The Go `check_interval` cap is dead weight and was
  not ported.
- **`std::sync::MutexGuard` is never held across `.await`.** Flow
  creation binds/connects *outside* the lock; the benign race (two
  flows for one src) is safe because each relay removes only its own
  entry.
- **Tokio-native drain:** `tokio_util::task::TaskTracker` replaces
  Go's `sync.WaitGroup` + manual `select`/timeout dance for the
  graceful-shutdown drain.
- **`RunError::Bind`** carries the `BindError` source (mirrors Go's
  `fmt.Errorf("forwarder: start %s %s: %w")`).

### T4: health server (axum): /healthz, /readyz, /status
**Depends on:** T3
**Verification:** unit tests for readyz bound-true/bound-false and /status
JSON shape. L0.
**Files:** `nix/packages/cococoir/src/health.rs`,
`nix/packages/cococoir/Cargo.toml`

### T5: logger (text/json) + two mains (cococoir-edge, cococoir-client)
**Depends on:** T4
**Verification:** flag parsing, config load, JSON round-trip; binaries
produced at `bin/cococoir-edge` and `bin/cococoir-client`. L0.
**Files:** `nix/packages/cococoir/src/logger.rs`,
`nix/packages/cococoir/src/bin/edge.rs`,
`nix/packages/cococoir/src/bin/client.rs`

**Architectural amendments:**
- **DRY mains.** Go duplicated ~85 lines across `cmd/edge` and
  `cmd/client`; both are now two-line wrappers over a shared
  `cococoir::app::run`. The `configFile` struct, flag parsing, signal
  handling, and health wiring exist once. (Violating "duplication is
  weight" was worse than the module boundary.)
- **tracing replaces slog.** `logger::Format::parse` + a global
  `tracing_subscriber` (text or JSON, `component` span). Config
  errors fail the binary at startup via exit 1, matching Go.
- **`-config`/`-log-format`/`-health-addr` CLI flags, JSON config
  shape, and binary names are unchanged** — the L2 edge test and the
  systemd unit ExecStart lines don't need to move.

### T6: replace Go package with Rust package in the flake
**Depends on:** T5
**Verification:** `nix build` the Rust package; `nix flake check` `doc-refs`
passes after ADR update (T8). L1.
**Files:** `nix/packages/cococoir/default.nix`,
`flake.nix` (if needed)

**Amendment:** `buildRustPackage` lives under `rustPlatform` in current
nixpkgs (`rustPlatform.buildRustPackage`), not top-level. `cargoLock`
vendors from the committed `Cargo.lock`. Nix only sees git-tracked
files, so the new Rust sources + `Cargo.lock` were staged (not
committed) mid-arc so nix could build them.

### T7: rewire `forwarder-unit-tests` check to cargo; run edge-forward
**Depends on:** T6
**Verification:** `forwarder-unit-tests` now runs `cargo test`;
`edge-forward` nixosTest passes end-to-end (curl through
edge→WG→client→python). L2.
**Files:** `nix/tests/default.nix`,
`nix/tests/edge/default.nix` (only if the test needs touch — it should not)

**Result:** No test rewiring was needed — `forwarder-unit-tests` is
`cococoirPkg.overrideAttrs (doCheck = true)`, which now runs
`cargo test` (42 tests) because the package is Rust. Both were
verified via a single `nix flake check`: all 21 checks pass,
including the full `edge-forward` 2-VM nixosTest
(`edge-forward: PASS`). The Rust forwarder passed the same
curl-through-WG→python + health-endpoint assertions the Go code was
verified against, on the first full run — the calibration core
result. One real contract fix surfaced by the oracle: Go's `/status`
used `json.MarshalIndent` (2-space), and the L2 test asserts the
spaced string; axum's `Json` emits compact JSON. Fixed in
`src/health.rs` to pretty-print to match.

### T8: delete Go module + internal/store; record ADR in PLAN.md
**Depends on:** T7
**Verification:** `rg --files | rg '\.go$'` empty under the package; `nix flake
check` green; `doc-refs` sees the new ADR. L1.
**Files:** `nix/packages/cococoir/` (delete go.mod, go.sum, *.go, store/),
`PLAN.md`

**Done:** Go module + `internal/store` deleted (0 `.go` files). ADR-024
recorded (supersedes ADR-017's language; bounded scope survives). Stale
Go references in PLAN.md updated (v0 table, v0 section, v2 extensions,
embedded dashboard, v3). All 21 flake checks pass including `doc-refs`.

### T9: measure and record calibration; update docs/STATUS.md
**Depends on:** T8
**Verification:** time-taken recorded in this proposal; STATUS.md "Works"
mentions Rust forwarder with L0/L2 proofs. L1 (doc-refs).
**Files:** `.specify/specs/rust-forwarder-port/proposal.md`,
`docs/STATUS.md`

## Calibration result (2026-08-03)

**Size:** Go baseline was 2,362 lines (incl. 572 test lines) across
8 files + 2 mains. The Rust crate is 2,059 lines across 8 modules +
2 binaries + `Cargo.toml` + `default.nix` — ~13% fewer lines, with
`internal/store` deleted (not ported) and the duplicated mains DRYed
into `app::run`.

**Verification achieved:** 42 `cargo test`s pass; all 21 flake checks
pass, including the full `edge-forward` 2-VM nixosTest running the
Rust binaries. One contract fix was caught by the L2 oracle
(`/status` must pretty-print like Go's `MarshalIndent`).

**Velocity signal:** the full arc (skeleton → validation → retry →
TCP/UDP serving → health → mains → nix packaging → Go deletion →
docs) completed in one session with ~5 compile-fix rounds, no
correctness regressions found by tests after the initial round-trip
helpers were made retry-aware. The port was *lower-friction* than the
Go original's line count suggested — Rust's enum/`Default`/type
system absorbed several validation paths Go needed runtime checks
for. This is a green light for the greenfield half of
`writing/llm/rust-rewrite.md`, subject to the proposal's strongest
objection (the forwarder is I/O-glue, not schema-shaping; the
greenfield config agent is where modeling actually pays).

## Strongest objection

The calibration could be a self-fulfilling rewrite. The forwarder is the
*least* type-shaped code in the whole role — dumb socket I/O, which Rust
protects least — so a fast clean port says "Rust is fine for I/O glue," which
tells us almost nothing about the *actually hard* greenfield: the schema-bound
config agent and the sanitized telemetry collector. If the port drags instead,
we've spent the scarcest resource (founder attention, pre-customer-1) on
dormant B2B infra that no customer will ever feel, and the honest calibration
"answer" was knowable from the plan's own ceiling paragraph (external services
and boot ordering dominate failures, not language). The strongest defense: the
port is bounded (one module, ~2.3k lines), has an oracle, and its *worst*
outcome is a bounded, measured "Rust is a bad fit, keep Go" — which is itself
worth knowing before committing the next 20k lines. The risk is only real if
we let a clean velocity number override the business sequencing argument.
