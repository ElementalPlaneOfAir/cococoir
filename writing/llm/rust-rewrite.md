# Rust rewrite — design plan

Status: finalized discussion, not implemented. Companion: `writing/human/rust-vs-go.md`.

## 1. Language: Rust for the entire Go role, now

All Go — forwarder, `cmd/edge`, `cmd/client`, config agent, control plane —
moves to Rust in one move. Single language project-wide.

~2.3k lines Go today, ~1.3k in `internal/forwarder` (v0 B2B infra the
single-machine v2 homelab doesn't use, but v3 reintroduces — ADR-015/016).
Homelab-relevant code (prober, journald, dashboard, config agent) doesn't
exist yet. Nothing deployed, so this is port-with-oracle plus greenfield.

### Why Rust (the usual reasons don't apply)

Memory safety is a wash (both GC'd); performance and binary size are
irrelevant (the box runs .NET/Python apps). The real case:

1. **Schema/type modeling.** The v2+v3 thesis — curated schema → config →
   Nix rebuild — is a type-shaped problem: service enum, strict
   deserialization, exhaustively-checked config. The forwarder is dumb I/O;
   the config agent and control-plane generator are where modeling pays.
2. **LLM feedback loop.** This project is LLM-driven (AGENTS.md). Rust's
   compile-time checks catch an agent's mistakes before runtime — a tight
   self-correction oracle, and why LLM Go→Rust rewrites go well.
3. **Boundary strictness.** Most bugs come from jellyfin, dex, cryptpad, etc.
   Rust can't fix them, but strict deserialization fails loudly on malformed
   input instead of silently accepting it — what a telemetry consumer of
   untrusted data wants.

**Ceiling:** we control ~2.3k lines; the failure surface is dominated by
external services and boot ordering (the jellarr P0 is a startup race, not a
language bug). Rust covers the small share; the language-agnostic L1/e2e
harness carries the big one.

### Sequencing: one move, no islands

Deferring the forwarder port was rejected under the zero-debt policy: a Go
island is a permanent two-language tax, and v3 needs forwarding anyway —
deferring means rewriting at the 10-20-customer moment, the most expensive
one. Fix now, before anything is built on top.

Port-now is also safest: 572 lines of unit tests (`forwarder_test.go`) plus
the 2-VM test (`nix/tests/edge/`) oracle the port against; the untested mains
are thin. Greenfield Rust has no oracle — the harness verifies it. The port
goes with the move, not after.

## 2. Architecture: two trust domains, not one binary

- **Box agent** (evolves `cococoir-client`): on the box. Telemetry +
  config writing + `git`/`nixos-rebuild`. Must work offline.
- **Remote console** (v3 control plane): provisioning, Hetzner, Postgres,
  multi-tenant. Runs where the operator runs it.

The split is a security boundary: telemetry ingests *untrusted* input
(journald, probe responses); the config path has *root and triggers
rebuilds*. Co-located, an exploited log parser could reach `nixos-rebuild`.

"One continuous system" = one shared config schema + OTEL wire format + flake
layout, not one binary.

## 3. Dashboard: HTMX server-side rendering

Server-rendered HTML (HTMX fragments), not an embedded JS SPA.

**Why:** the dominant dashboard bug class — client state diverging from
server state — is eliminated. No client state; the rendered HTML *is* the
server's understanding of the box. It also composes with the config editor:
schema-rendered form → POST → fragment re-rendered with validation inline.
Validation lives next to the config generator; the GUI-to-Nix gap collapses
to a form whose submit calls the generator.

Rust strengthens it: compile-time type-checked templates (maud/askama) can't
reference a nonexistent field — the HTML can't drift from the schema.

**Caveat:** HTMX does real-time charts (latency sparklines) poorly. Scoped
exception: one `<canvas>` + chart lib fed by a JSON endpoint
(`:9090/api/{probes,logs}`), or plain tables/bars.

**Remote console stays separate** — the ship-out path is OTLP export, a
different pipeline; don't render the remote console with the local
dashboard's code.

## 4. Telemetry: in-process collector, sanitized fan-out

### Three OTEL signals

OTEL has three parallel signals sharing one transport — **traces, metrics,
logs**:

| Signal | Source | Dashboard panel |
|---|---|---|
| Logs | everything, via journald → converted | "Recent logs" tail |
| Metrics | prober (latency, availability) | health cards, sparklines |
| Traces | our Rust binaries only | probe/job traces |

Services don't emit OTEL — none runs an OTLP exporter. The universal
collector on a NixOS box is **systemd journald** plus the **prober** for
synthetic checks.

### Flow

```
journald + probe ──normalize──▶ in-process collector
                                    ├──▶ in-memory ring buffer ──▶ HTMX dashboard
                                    └──▶ sanitize ──▶ buffered OTLP export ──▶ cloud
```

One collector, two sinks — a component inside the box agent, not a separate
process (that earns its complexity only with aggregate scale).

### Non-negotiables

- **Bounded buffering + drop policy.** A dead/slow cloud connection degrades
  the cloud pipeline, never the local dashboard or box. Cap the batch queue,
  drop-if-full. Otherwise a network blip becomes a local memory problem — a
  silent-failure seam, which this project treats as a bug.
- **Sanitization at the fan-out boundary.** The cloud sink gets a curated
  subset — PII scrub, no secrets (ADR-006; v2.sanitize in PLAN.md). Mandatory
  filter, not an afterthought; the fan-out is a trust boundary.

### Share the contract, not the runtime

| | Local | Cloud |
|---|---|---|
| Question | "Is my service up right now?" | "Is this service trending down across customers?" |
| Depth | Shallow, immediate | Deep, historical, joined |
| Latency | Millisecond, real-time | Batched, minutes |
| Failure | Box works offline | Ingest not poisoned by one box |

Share the contract — OTEL semantic conventions + an alert-rule DSL both sides
parse, one models crate. Not the analysis runtime: shared code ships a rule
bug everywhere and ties the box to the cloud's schema churn.

### Journald ingestion: reference spec, not dependency

The OTLP Collector's `journald` receiver does our planned ingestion (tail
journalctl → parse → OTLP records), proving it's a solved problem. Crib its
feature set — unit/priority filtering, regex on message, journal fields →
semantic conventions, cursor persistence for duplicate-free resume — don't
adopt it.

In-process Rust beats it: read the journal socket directly with `__CURSOR`
resume — no `journalctl` subprocess, no second binary. ~300 known lines.

### Reject opentelemetry-collector

It's a generic pipeline, a second process, and a new config surface —
violating under-50-lines customer config, no-foisted-integration-complexity
(AGENTS.md), and ADR-011 ("deployment tool, not a library"). The hard parts —
local sink, sanitize boundary, schema-bound config, prober metrics — are
custom regardless.

## 5. Decisions locked

- Rust for the entire Go role, in one move. No Go islands; the forwarder ports
  with the move (oracle + v3 needs it, ADR-015/016).
- Two trust domains: box agent (offline-capable) vs remote console. Shared
  contract, not shared runtime or binary.
- Dashboard is HTMX SSR with compile-time templates; charts are a scoped
  exception fed by JSON endpoints.
- Telemetry is in-process: journald + probe → collector → local buffers +
  sanitized OTLP export. Bounded buffers, sanitize at the boundary.
- Journald reader is in-house, cribbed from the OTLP journald receiver, reading
  the socket directly with `__CURSOR` resume.
- No opentelemetry-collector.
