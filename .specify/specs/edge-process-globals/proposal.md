# Edge process globals: `&'static` routing table, forwarder, control plane

## Premise

The control plane currently threads `Arc<RoutingTable>`, `Arc<Forwarder>`,
and `Arc<ControlPlane>` through an `AppState` struct into every HTTP
handler, and passes `&RoutingTable`/`&Forwarder` as parameters into
`signup`/`delete`/`rehydrate`. All three values are **process-lifetime
singletons**: built once in `main()`, never dropped, never reparented,
lived until the process exits. That is exactly the "data that remains
valid throughout the lifetime of the program" category — `&'static`
territory, not `Arc` territory.

An `Arc` is a lie here: it signals "this may be destroyed or reassigned
by any thread at any time," which is false. Every `Arc` incurs
increment/decrement overhead on every copy and muddies what a global
actually is. The fix is to make the three singletons true `'static`
process globals via `OnceCell`, and let the `DashMap`/internal locks
they already contain provide the (fine-grained, already-efficient)
synchronization. `AppState` and the parameter-passing disappear.

This re-opens the "inject vs global" decision settled in
`control-plane-source-of-truth` (which chose injected `Arc` for
testability). That decision optimized for test wiring over production
readability. The lifetimes principle in `writing/human/lifetimes_in_rust.md`
argues the opposite priority: production clarity first, test harnesses
absorb the noise. This proposal adopts that.

## Acceptance criteria

- [x] `signup` and `delete` take **no** `table`/`forwarder` parameters;
      they read the process globals. `rehydrate` stays a **param'd
      recovery primitive** (`rehydrate(&self, table, forwarder)` — fills
      *given* objects from Redis) because it runs during init, *before*
      the table global is published; it cannot read a global that does
      not yet exist. (L0: compile + existing control-plane tests pass
      unchanged in behavior)
- [x] `AppState` no longer carries `table`/`forwarder`; the three
      singletons live in `OnceCell` globals set once at boot. (L0:
      compile; `edge.rs` sets them in `main()` before serving)
- [x] The `app.rs` **client** binary is untouched — it keeps its local
      `Forwarder`, which is correct because the client is a separate
      single-tenant process, not the edge. (L0: `cococoir-client` still
      builds + runs)
- [x] No behavior change: the edge's signup→list→delete round trip
      still allocates `/128`s, adds WG peers, binds forwards, and the
      edge public key stays stable. (L0: `redis_store_round_trip` +
      control-plane unit tests pass; live Redis round trip re-run)

## Smallest version

Three process globals, all `tokio::sync::OnceCell` **initialized via
`get_or_try_init` whose init future does construction + hydration
together** — because the routing table and forwarder are **recovered
from Redis on every boot** (`rehydrate()` rebuilds both from the durable
store), and folding hydration into init is the only way the accessors
can guarantee a *hydrated* singleton rather than an empty one.

- `FORWARDER` — `get_or_try_init` → `Forwarder::new_live(Config::default())`.
- `CONTROL_PLANE` — `get_or_try_init` → construct + `edge_public_key()`
  (touches Redis once) so unreachable Redis returns `Err`, not a crash.
- `ROUTING_TABLE` — `get_or_try_init` → construct + `rehydrate()` from
  Redis (needs `&CONTROL_PLANE` + `&FORWARDER`, so it inits last).

Because `get_or_try_init` only ever publishes a **fully-hydrated** value,
the accessors are pure and safe:

```rust
fn routing_table() -> &'static RoutingTable {
    ROUTING_TABLE.get().expect("globals not initialized")
}
```

No consumer ever sees an unhydrated table — hydration is inseparable
from initialization. Boot order in `main()`:
`init_globals(redis_url, subnet, wg_subnet)` (inits forwarder → control
plane → table/rehydrate) before any traffic is served.

**Test seam = manual `set()` before the test, bypassing hydration.**
`set()` and `get_or_try_init` are mutually exclusive on one `OnceCell`
— a test that `set`s its own instance (e.g. a mock WG client, no Redis)
never triggers `get_or_try_init`, so it gets exactly the state it wants
with zero network. Production always hydrates via `get_or_try_init`;
tests always hand-seed via `set` — two intentional, separate paths, so
the "is it hydrated?" question never bites. The whole control-plane test
module needs one instance of each, so `set`-once-per-process is not a
constraint. No `#[cfg(test)]` branch in the accessor, no unsafe override.

`AppState` deleted. `signup`/`delete`/`rehydrate` drop their
table/forwarder params and read the globals. Handlers drop their
`Data<&AppState>` and call the control plane directly. `app()` takes no
state. The `cococoir-controlplane` entry (`controlplane_entry`) is
updated to set the same globals. DNS-on-signup is **deferred** to the
next arc and will add a `DnsClient` on top of this.

## Alternatives considered

- **Keep injected `Arc` (status quo)** — case for: already built,
  tests construct their own instances cleanly. Case against: lies about
  lifetime, three values threaded through every handler + method param,
  an `AppState` struct that exists only to ferry singletons, refcount
  overhead. Rejected: the values are provably process-lifetime.
- **`&'static RwLock<RoutingTable>` (user's first sketch)** — case for:
  explicit marker of internal mutability. Case against: the `DashMap`
  inside `RoutingTable` *is already* the internal mutability + lock, so
  a `RwLock` wrapper is redundant weight on the airplane. `OnceCell`
  communicates "created once, live forever" more accurately than a
  lock-protected cell. Rejected in favor of `OnceCell<RoutingTable>`.
- **Make only `RoutingTable`+`Forwarder` global, keep `ControlPlane`
  injected (Option B)** — case for: smaller diff, `ControlPlane` is a
  client-like resource. Case against: inconsistent — `ControlPlane` is
  the same kind of singleton as the other two; keeping it injected
  leaves `AppState` alive with one field and two different ownership
  models in one file. Rejected: uniformity (Option A) is cleaner and
  this is the last point in the arc's life to make the change cheap.

## Architecture decisions

No new ADR. This is an implementation correction to the "three
lifetimes" resolution in `control-plane-source-of-truth`: the routing
table + forwarder + control plane are process-lifetime data, so they
belong in `&'static`/`OnceCell`, not injected `Arc`. The
`writing/human/lifetimes_in_rust.md` taxonomy (owned / `'static` /
`Arc`) is the governing principle; `OnceCell` is the `'static`-with-
late-init vehicle because the singletons are built in `main()` after
CLI/config parsing.

The routing table and forwarder are **recovered from Redis on boot**, not
empty — `rehydrate()` is the async recovery step that rebuilds both from
the durable store. So "sync construction" is only true of the empty
allocation; the content is Redis-recovered. The `tokio::sync::OnceCell`
+ `get_or_try_init` shape exists precisely so that Redis-unreachable
boots and tests return `Err` (fast fail, no test outage) instead of
panicking on a `set` of a half-initialized singleton.

## Tasks

### T1: ✔ Add the `OnceCell` globals + `init_globals()` (hydration in init)
**Depends on:** none
**Verification:** compiles; `get_or_try_init` returns `Err` on
unreachable Redis (no panic); accessors return `&'static` hydrated
values; a test `set()` pre-seed bypasses hydration
**Files:** `src/controlplane/mod.rs`, `src/bin/edge.rs`

### T2: ✔ Drop `table`/`forwarder` params from `signup`/`delete`; `rehydrate` stays param'd
**Depends on:** T1
**Verification:** existing control-plane tests compile + pass; they
`set()` the globals as a pre-seed instead of passing params to
signup/delete; `rehydrate` is called with a local table+forwarder during
init only
**Files:** `src/controlplane/mod.rs`

### T3: ✔ Delete `AppState`; handlers read globals; `app()` takes no state
**Depends on:** T2
**Verification:** `app()` builds a `Route` with no `.data(state)`;
handlers compile with no `Data<&AppState>`; `controlplane_entry`
updated to call `init_globals()`
**Files:** `src/controlplane/mod.rs`

### T4: ✔ Wire `init_globals()` in `edge.rs::main()`; leave `app.rs` untouched
**Depends on:** T3
**Verification:** `edge.rs` calls `init_globals()` (forwarder → control
plane → table/rehydrate) before serving; `cococoir-client` (via
`app.rs`) still builds + runs its local forwarder
**Files:** `src/bin/edge.rs` (only)

### T5: ✔ Run L0 + live Redis round trip
**Depends on:** T4
**Verification:** `cargo test` all green (incl. `redis_store_round_trip`
with `REDIS_URL` set); `cargo build --bins` both binaries
**Files:** none (verification only)

### T6: ✔ Split edge-identity install from the pubkey getter (pre-existing bug)
**Depends on:** T3
**Verification:** `redis_store_round_trip` asserts the edge private key
is installed **once** (boot), not per-signup; `edge_public_key()` returns
the same pubkey with no install side-effect
**Files:** `src/controlplane/mod.rs`, `src/bin/edge.rs`
**Note:** surfaced by running `redis_store_round_trip` against live Redis
(never exercised in the 121-test baseline, which skipped it for lack of
`REDIS_URL`). Root cause: `edge_public_key()` reinstalls the key on every
call when a key already exists (`had_existing`), so `signup()` (which
calls it per signup) causes repeated `set_private_key` calls. Fix: make
`edge_public_key()` a pure getter and move the install to boot-time in
`init_globals` — the correct seam now that init owns hydration.

## Strongest objection

This is a **testability-to-readability trade shipped as if it were free.**
The control-plane unit tests must now install process globals before
they run (construct + `set` a `RoutingTable`/`Forwarder`/`ControlPlane`),
where the old injected design let each test build and pass its own
instances with zero setup. Today that cost is small — the whole
control-plane suite needs exactly one instance of each, and
`OnceCell::set`'s collision-panic makes double-install a loud programmer
error, not silent cross-talk. But it is a **latent trap**: the moment a
future test needs *two* different tables or forwarders in one process,
`OnceCell` (set-once) cannot express it, and the resolution is ugly —
split the binary, or fall back to `Box::leak`-style per-test globals
behind a `#[cfg(test)]` store. If that day comes, the injected-`Arc`
design was the lesser evil and this refactor should be partially
reverted (e.g. keep `RoutingTable` global but re-inject the `Forwarder`).
The bet is that the edge's control-plane tests stay single-instance;
that bet is what this whole change rides on, and it is the single best
argument that the change is mistimed.
