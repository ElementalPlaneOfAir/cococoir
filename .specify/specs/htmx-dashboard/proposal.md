# HTMX dashboard — local log aggregation + consent gate

Status: proposal (not yet implemented).

Session 2026-08-07: reviewed with user. Sequencing confirmed (dashboard
first, config editor deferred, OTEL deferred but data-shape-first). T5
journald decision made: `sdjournal` crate (see T5). Ready to implement.

Session 2026-08-08: T0 (axum→poem + OpenAPI) implemented and verified
(L0 + L1 + L2 green), committed `de0c195`. Next task: T1.

## Premise

The v2 home server needs a dashboard: a customer-facing way to see, on the
local box, what its services are doing — probes, recent logs — with a consent
gate where the user decides whether undredacted logs may be proxied onward to
cococoir for debugging help. The gate is local-only for now; the onward
transport is v3 (OTLP edge export). The dashboard is the entry point for a
later config-editor arc: the user lands on the dashboard, and from there the
same server eventually edits the generated config.

Why now: v2's services, storage, and OIDC are built and the e2e is the only
remaining gate. The dashboard is the last customer-visible v2 piece and the
natural place to prove the observability spine (`probe` + `journald` + an
OTEL-shaped in-memory store) that v3's exporter will consume.

Deliberately out of scope:
- **Config editor** (parse-Nix → in-memory → regenerate one static config file
  → git commit → `nixos-rebuild` on Apply). Separate arc, after this one. This
  arc only serves the existing generated config; it does not edit it.
- **OTEL SDK / OTLP export.** This arc builds the store and emits into it with
  the *OTEL data shape* (log records + probe spans) so wiring the SDK later is
  an adapter, not a rewrite. No `opentelemetry` crate yet, no transport.

## Acceptance criteria

- [ ] L0: `cargo test` passes. New tests cover: empty-`forwards` no-op
      forwarder, config with `services`, OTEL-shaped log-record parsing from a
      journald JSON line, probe span shape, store capping/eviction,
      consent persistence round-trip, dashboard routes. Maps to T1–T5, T7.
- [ ] L1: `nix flake check` passes — `doc-refs`, `contract-conformance`,
      `vmtest-wiring` green, plus a new `vmtest-wiring` assertion that the
      rendered client config JSON contains the `services` list with the
      factory's `healthUrl` + `journald.units`. Maps to T6, T8.
- [ ] L2: `scripts/vmtest-e2e.sh` PASS, including new bootstrap assertions:
      dashboard HTML serves at `:9090/`, `/api/logs` returns records after a
      service writes to the journal, consent toggle round-trips. Maps to T8.
      This is also the P0 (jellarr) re-verification run — the e2e gate that
      has been blocked.
- [ ] Existing `/healthz`, `/readyz`, `/status` contracts unchanged (the L2
      edge test and vmtest keep asserting them). Maps to T5.
- [ ] The `forwards = []` no-op that PLAN.md claims works actually works —
      PLAN-vs-code drift fixed. Maps to T1.
- [ ] No OTEL SDK dependency and no network egress from the box in this arc.
      The consent flag is persisted locally and the forwarder is the only
      network path. Maps to T7.

## Smallest version

An HTMX page served by `cococoir-client` at `127.0.0.1:9090/` showing:
services (up/down from last probe), the last N probe spans, and the last N
journald log records per service — plus a single consent toggle ("allow cococoir
to collect these logs for debugging") that persists locally. The `probe` +
`journald` tailer + in-memory store are the plumbing; the dashboard is the only
customer-visible surface. Nothing else.

## Alternatives considered

- **Vanilla HTML/JS embedded dashboard (PLAN.md as written)** — case for:
  zero dependencies, no new concepts. Case against: manual `fetch`+render+
  poll loop is exactly the code HTMX removes; the user wants HTMX; the "no
  framework" rule was a constraint on build-step weight, not on small scripts.
  Winner: HTMX, vendored as a single embedded file, no build step preserved.
- **Serve the dashboard from Caddy** — case for: no new listener. Case
  against: the client binary already owns `:9090` for health; the dashboard
  needs the in-process store, so it must live in the binary regardless.
  Rejected.
- **Store logs in SQLite / bbolt / a file** — case for: survives restarts.
  Case against: v2 is in-memory by design (ADR: "OTEL SDK in-process,
  in-memory"); log history across reboot is not a customer-visible v2 need.
  Rejected for now; revisit when the editor arc or v3 arrives.
- **Pull `opentelemetry` crate now** — case for: the "right" types from day
  one. Case against: adds a heavy SDK before any consumer exists; the user
  explicitly deferred OTEL. The store is built to the OTEL data shape now so
  the SDK wiring is an adapter. Deferred by design.
- **`reqwest` for the prober** — case for: familiar. Case against: heavy
  dep for a GET. poem ships no HTTP client, so the choice stays open; a minimal
  `hyper`-based GET or `reqwest` with default features off is the decision in T4.
- **`journalctl -f -o json` subprocess for the tailer** — case for: zero
  deps, trivially testable. Case against: keeps a whole subprocess + pipe
  buffer alive for the box's lifetime (memory footprint on a constrained
  customer device), depends on the `journalctl` binary's output format
  staying stable, and breaks if journald output mode changes. Rejected for
  the `sdjournal` crate (pure Rust, inotify-backed live follow, bounded
  queues, per-unit `match_exact("_SYSTEMD_UNIT", ...)` filters, tokio
  feature, documented memory-constrained config via `max_open_files` +
  `mmap_policy`). See T5.

## Architecture decisions

- No new ADR. Extends ADR-008 (prober/journald/dashboard in `cococoir-client`)
  and the v2 "OTEL SDK in-process, in-memory" rule with the OTEL-data-shape
  store; records a small amendment in PLAN.md that the dashboard is HTMX
  rather than vanilla JS (the "no framework" wording was about build steps).
- **Framework: poem + poem-openapi (2026-08-08).** The health server migrates
  from axum to poem so the whole web surface documents itself as OpenAPI v3
  with bundled swagger UI (offline-safe). One framework for health + dashboard;
  the swap is bounded to `health.rs` because that is the crate's only web
  surface. See T0.
- The store's record types mirror the OTEL spec shapes (log record with
  severity/body/attributes; span with name/kind/status/duration/attributes) so
  v3's OTLP exporter consumes them directly.
- `cococoir-client` owns the dashboard. `cococoir-edge` is untouched (v0
  contract frozen).
- The config file gains an optional `services` list (name, healthUrl,
  journald units) generated by the Nix module from the factory's internal
  options — no new customer-facing option. The forwarder's `forwards` stays
  the forwarder's; empty list is a no-op.

## Tasks

### T0: migrate health.rs axum → poem + OpenAPI
**Depends on:** none
**Verification:** `/healthz`, `/readyz`, `/status` byte-identical on the wire
(pretty JSON with 2-space indent + trailing `\n`, content-type `application/json`);
swagger UI serves at `:9090/docs` and the spec at `:9090/openapi.json`, both fully
offline (poem-openapi's `swagger-ui` feature bundles JS/CSS via `include_str!`,
no CDN — verified from source); port all 6 health tests from `tower::ServiceExt`
to `poem::test::TestClient` unchanged in assertion; `cargo test` passes; L2
`edge-forward` nixosTest still green (it curls the same three endpoints).
**Files:** `nix/packages/cococoir/Cargo.toml`,
`nix/packages/cococoir/src/health.rs`

- [x] DONE 2026-08-08. `cargo test` 42/42 pass; live curl at `:19095` shows
      `/healthz` `ok\n`, `/readyz` 200 `{"ready":true}`, `/status` byte-exact
      pretty JSON, `/docs` serves bundled swagger UI (1.6 MB HTML, no CDN),
      `/openapi.json` serves the v3 spec with all three paths and honest schemas
      (`/status` → `{}` any object, `/readyz` → 200+503 typed). L2
      `edge-forward` nixosTest ran and PASSed in `nix flake check` (boots real
      VMs, curls all three endpoints byte-exact). `nix flake check` all green.
      Committed as `de0c195`.

**Why a framework swap:** the user has first-hand repeated pain with axum+OpenAPI
addons (utoipa/aide); poem-openapi derives the OpenAPI v3 spec from the code
("compiles ⟹ spec-correct", no doc rot), serves swagger UI at `/docs`, and the
crate's entire web surface is one file (`health.rs` ~170 lines) — cheap to swap
now, expensive later once T3–T7 pile routes on. The health endpoints become
`#[oai]` operations; `/status`'s byte-exact body is preserved by a derived
`ApiResponse` with `actual_type = "Json<serde_json::Value>"` (runtime header +
body kept byte-identical, spec schema honest as an arbitrary JSON object).

### T1: allow empty `forwards` (fix PLAN-vs-code drift)
**Depends on:** none
**Verification:** `Forwarder::new` accepts `forwards = []` and `run()` drains
immediately; `readyz` returns 503 (no bound forwards); existing
`new_rejects_empty_forwards` test rewritten to assert the no-op instead. L0.
**Files:** `nix/packages/cococoir/src/forwarder.rs`

### T2: config gains optional `services` list
**Depends on:** T1
**Verification:** serde parses `{"forwards": [], "services": [...]}` and
rejects unknown fields; `deny_unknown_fields` still enforced; edge configs
without `services` parse identically. L0.
**Files:** `nix/packages/cococoir/src/app.rs`

### T3: OTEL-shaped in-memory store (log records + probe spans)
**Depends on:** T2
**Verification:** capped ring buffers evict oldest first; snapshot is a copy
(mutating a returned snapshot does not affect the store); record structs match
the OTEL field shapes. L0.
**Files:** `nix/packages/cococoir/src/otel.rs`, `nix/packages/cococoir/src/lib.rs`

### T4: prober (HTTP GET per service → probe span)
**Depends on:** T3
**Verification:** probes the configured `healthUrl`s on an interval, records
span shape `{name, status, duration, attributes: {http.url, http.status_code,
http.method}}`; timeout doesn't hang the loop; a local echo server test
exercises 200 and connection-refused. L0.
**Files:** `nix/packages/cococoir/src/probe.rs`,
`nix/packages/cococoir/Cargo.toml` (if a client dep is needed)

### T5: journald tailer (per service units → log records)
**Depends on:** T3
**Verification:** given a journald entry, produces an OTEL-shaped log
record `{time, severity, body, attributes: {pid, unit}}`; missing/extra fields
handled; live-follow via `sdjournal::LiveJournal` with per-unit
`LiveFilter`/`match_exact("_SYSTEMD_UNIT", ...)`; memory-constrained config
(`max_open_files`, `mmap_policy`) set; L0 unit tests cover entry→record
mapping with fixture entries. L0.
**Files:** `nix/packages/cococoir/src/journald.rs`,
`nix/packages/cococoir/src/lib.rs`,
`nix/packages/cococoir/Cargo.toml`

**Decision (2026-08-07):** use the `sdjournal` crate. Pure Rust
(journal files read directly — no `journalctl` subprocess, no libsystemd),
actively maintained (v0.1.22, docs.rs 2026-07-28, ~22k recent downloads,
100% documented), inotify-backed live watching, tokio integration, bounded
queues, and explicit memory-constrained settings (`JournalConfig::max_open_files`,
`mmap_policy: Never`). One `LiveJournal` fans out to per-unit
`LiveSubscription`s — one engine, multiple units, matching the factory's
`journald.units` list. Rejected subprocess approach (see Alternatives).

### T6: Nix module generates `services` JSON from the factory options
**Depends on:** T2
**Verification:** evaluating the vmtest config renders a client config whose
`services` list matches the enabled factory services' `healthUrl` +
`journald.units` (the `vmtest-wiring` assertion). L1.
**Files:** `nix/nixos-modules/client.nix`,
`nix/nixos-modules/services/_contract.nix` (only if the factory needs to
surface a `config` export)

### T7: dashboard + consent gate (HTMX, embedded, on the client's `:9090`)
**Depends on:** T4, T5, T6
**Verification:** `/` serves HTML referencing an embedded htmx script (no
external CDN, no build step); `/api/services`, `/api/probes`, `/api/logs`
return the store's JSON; consent GET/POST round-trips to a local file
(e.g. `/var/lib/cococoir/consent.json`); `/healthz`, `/readyz`, `/status`
unchanged. L0 via axum router tests + one manual curl in a running VM.
**Files:** `nix/packages/cococoir/src/dashboard.rs`,
`nix/packages/cococoir/src/consent.rs`,
`nix/packages/cococoir/src/health.rs` (route wiring)

### T8: vmtest-e2e bootstrap assertions for the dashboard
**Depends on:** T7
**Verification:** `scripts/vmtest-bootstrap.sh` adds: `curl :9090/` returns
HTML, `/api/logs` non-empty after a service logs, consent toggle POST
persists; `scripts/vmtest-e2e.sh` green — the P0 (jellarr) re-verification
run. L2.
**Files:** `scripts/vmtest-bootstrap.sh`

## Strongest objection

This arc builds an in-process, in-memory observability spine with no consumer
outside the local dashboard, and the "OTEL-shaped store" is a bet that the
hand-rolled shapes will match the eventual `opentelemetry` SDK well enough to
be an adapter rather than a rewrite — but v3 may also want metrics, resources,
and PII sanitization (v2.sanitize is already backlog), which the store doesn't
model. If v3 reshapes the store, the dashboard survives but the spine is
partially reworked. Strongest defense: the dashboard is the customer-visible
goal and works regardless; the store is small and the shape is deliberately
documented against the OTEL spec; and this arc provably unblocks the P0
re-verification that everything else is waiting on.
