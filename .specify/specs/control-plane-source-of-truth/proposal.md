# Control plane as source of truth

## Premise

The IPv6 edge demo baked per-customer state (forwards, customer `/128`,
AAAA records) into tofu + static NixOS config. That is the wrong layer
holding runtime state, and it caused two dark boots (NIC name guessing,
`ens3` → `eth0` → actually `enp1s0`). The runtime truth is: customer
`/128`s are allocated by the control plane at signup, over the box's
lifetime, and change as customers come and go. This arc makes the
control plane the source of truth for allocations, forwards, DNS, and
WG peers — and stops tofu from rendering any of it.

## Acceptance criteria

- [ ] A new customer signup allocates a `/128`, and the edge **live**
      binds a `[customer-v6]:443` listener (and `:80`) without restart
      and without dropping existing tunnels. (L0: forwarder mutation
      tests; L2: live box)
- [ ] Deleting a customer removes the listener live. (L0)
- [ ] The forwarder's listener set is a runtime thing: an in-memory
      routing table drives it, not a static JSON file. (L0: tests
      construct a table, add/remove forwards)
- [ ] Tofu no longer renders customer forwards, customer `/128`
      interface addresses, or customer AAAA records. (L1: inspect
      rendered edge.nix / dns.tf)
- [ ] The box gets its own address via DHCP (no baked NIC name, no
      static IP). (L1: edge.nix uses `useDHCP`; L2: live box reachable
      after boot)

## Smallest version

The edge box is one tokio app: the forwarder (with live add/remove +
`IPV6_FREEBIND`) + the control plane HTTP API sharing an
`Arc<Forwarder>`. Signup allocates, stores in Redis, adds the forward
live. The routing table (`routing_config.rs`) is the in-process truth
the forwarder reads and the control plane writes. Hetzner DNS AAAA
records are **deferred** (DNS is not on this arc's critical path — the
demo works by direct /128 access). Customer-side (example123) config is
**unchanged** — it still dials out with its static WG key.

## Alternatives considered

- **Tofu renders everything (status quo)** — case for: single source of
  truth, already built. Case against: it's the wrong layer for runtime
  state, caused two dark boots, cannot do live signups. Rejected.
- **Separate control-plane binary + forwarder, IPC between them** —
  case for: process isolation. Case against: needs a socket/HTTP
  protocol, a reload or notify path, more moving parts. Rejected:
  one process shares memory, no boundary to cross (ADR-025's "no
  restart" requirement becomes trivially satisfiable).
- **Packet-time routing (lookup dest IP per packet in a DashMap)** —
  case for: one shared listener, decision per packet. Case against:
  userspace lookup on the hot path, port-mapping per packet, and a
  rewrite of the proven per-listener forwarder. The decision is made
  once, at bind time, per customer — the kernel demuxes by
  address:port. Rejected (per-listener is simpler and already built).
- **Global `static LazyLock<DashMap>` vs injected `Arc<RoutingTable>`** —
  the user's preference is the global (OnceCell) for process-lifetime
  data; the counter-argument was testability and global-state
  contamination. Resolution: the routing table is built as a shared
  type; `main()` owns it and passes `Arc`s to both halves. Library
  code takes `&RoutingTable` — tests build their own table, no global
  to poison. (The "three lifetimes" argument — owned / `&'static` /
  `Arc` — is respected: the table is process-lifetime but injected,
  not ambient.)

## Architecture decisions

No new ADR: this is ADR-025's "runtime provisioning without disruption"
being implemented. The forwarder gains mutation methods; the control
plane stays Redis-backed; allocations stay `INCR`-based (`Subnet64`).

## Tasks

### T1: RoutingTable type (`routing_config.rs`)
**Depends on:** none
**Verification:** unit tests construct a table via `test_new()`, add +
remove customers, assert key set
**Files:** `src/controlplane/routing_config.rs` (+ `lib.rs` mod)

### T2: Forwarder live add/remove
**Depends on:** T1
**Verification:** integration test binds a forward, adds a second live,
asserts both forward; removes one, asserts traffic stops; `IPV6_FREEBIND`
set on sockets (assert via a bind to a non-local `/128`)
**Files:** `src/forwarder.rs`, `src/retry.rs` (freebind-aware bind)

### T3: Control plane writes routing table
**Depends on:** T1, T2
**Verification:** signup → forwarder bound (test asserts the listener
accepts); delete → listener gone
**Files:** `src/controlplane/mod.rs`

### T4: Edge = one tokio app
**Depends on:** T3
**Verification:** `cococoir-edge` runs forwarder + API in one process;
a signup against the live binary binds a listener (L2 on the box, or
L0 with a test harness)
**Files:** `src/bin/edge.rs`, `src/app.rs`

### T5: Edge NixOS config self-networking
**Depends on:** T4
**Verification:** edge.nix uses `useDHCP = true`, drops baked customer
forwards + customer `/128` interface addresses; flake evals; box comes
up reachable after a fresh install (L2)
**Files:** `remote-infra/tofu/templates/edge.nix.tftpl`,
`remote-infra/nix/edge.nix`, `remote-infra/tofu/render.tf`

## Strongest objection

This arc makes the edge's live state (routing table) and durable state
(Redis) two separate stores that can drift — if the forwarder crashes
between a Redis write and a bind, or a signup is written to Redis but
never bound, the box silently forwards nothing for that customer. The
demand for "no restart, no tunnel drop" pushed us to in-memory
mutation, but the recovery path (rebuild table from Redis on boot)
is only correct if every write is transactional and the reconcile-on-
boot actually runs before traffic arrives. The single process helps —
one code path writes both — but the boot-time reconciliation is
obligatory, not optional, and must be tested. If the drift risk is
unacceptable, the alternative is a restart-on-signup (simpler,
disruptive) — but that is precisely what ADR-025 forbids.
