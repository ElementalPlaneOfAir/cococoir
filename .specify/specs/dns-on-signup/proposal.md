# DNS on signup (per-customer AAAA records)

## Premise

Customers are reachable at their `/128` over WireGuard today, but only
by raw IP — ADR-025's `*.<username>.interdim.net` AAAA → `/128` mapping
is still baked into tofu as a **single static wildcard**
(`dns.tf`: `*.example123.interdim.net`). That is the wrong layer for
runtime state: a customer's DNS record must be created/removed as they
sign up and leave, over the box's lifetime, exactly like their `/128`,
WG peer, and forwards already are.

This arc makes the control plane provision DNS at runtime: `POST
/signup {"username":"bob"}` creates `*.bob.interdim.net` (+
`bob.interdim.net`) AAAA → the customer's `/128`, `DELETE` removes
them, and a **background reconcile loop** verifies (and re-applies)
the records continuously. It introduces the crate's first outbound HTTP
dependency (`reqwest`) and the first Hetzner-DNS-API client.
Resolution is a separate concern (a `hickory-resolver`-based function
that queries 1.1.1.1) — the API client only *provisions*.

Retiring the static `dns.tf` wildcard / `example123` path is **deferred**
to the next arc — this is the gate that makes that retirement safe.

## Acceptance criteria

- [x] `POST /signup` takes a JSON body `{"username":"bob"}` (a valid
      DNS label, unique — the username IS the customer's id). It
      creates the AAAA records `bob.interdim.net` and
      `*.bob.interdim.net` → the customer's `/128`, and the response
      carries the customer's `hostname` (`bob.interdim.net`). (L0:
      unit test with a mock DNS API client asserts the two upserts;
      L2: live box)
- [x] `DELETE /customers/:username` removes the customer's AAAA
      records. (L0: mock asserts the two removes)
- [x] A background reconcile loop verifies both records for every
      customer in Redis against real resolution (1.1.1.1) and
      re-applies mismatches — running once shortly after boot (~30s)
      and then on a ~2h interval. (L0: unit test on the reconcile
      decision function with a mock resolver + mock API client)
- [x] DNS failure does **not** fail a signup: the customer is still
      reachable at their `/128`, and the record self-heals on the next
      reconcile pass. (L0: mock DNS that errors → signup still returns
      201)
- [x] A missing/unreachable DNS config fails **at boot**, not on the
      first signup. (L0: `init_globals` returns `Err` when the DNS
      zone/token can't be resolved)
- [x] The provisioning `DnsApiClient` is provider-faithful: one record
      per call, full record name, typed IPv6; the "main + wildcard"
      policy lives above it; resolution is NOT part of the client.
      (L0: trait shape; no mechanism the customer never feels)

## Smallest version

- `controlplane/dns.rs`: `DnsApiClient` trait (`upsert_aaaa(name,
  ipv6)`, `remove_aaaa(name)`) + `HetznerDns` (the one real provider)
  + a `MockDnsApiClient` for tests. `HetznerDns` holds `zone_id`,
  `token`, and an `http: reqwest::Client` — the provider's own config,
  nothing about naming. Constructed by an inherent `HetznerDns::from_env()`
  (static config — env-driven, never changed without a restart).
- `HETZNER_DNS_CONFIG: LazyLock<HetznerDns>` as the single `'static`
  provider config global; `get_dns_api() -> &'static dyn DnsApiClient`
  hands out the singleton. `HetznerDns::from_env()` fails fast (missing
  env → boot `Err` via `init_globals`).
- `DOMAIN` is a **separate** `'static` `LazyLock<String>` (env
  `COCOCOIR_ROOT_DOMAIN`, default `interdim.net`) — the naming layer,
  above the provider config, owned by the orchestrator, not the DNS
  client.
- **Resolution is independent of provisioning**: a free
  `async fn resolve_aaaa(name: &str) -> Result<Vec<Ipv6Addr>, DnsError>`
  using `hickory-resolver` (tokio feature), querying a fixed resolver
  (1.1.1.1). Used only by the reconcile loop to *verify* applied state.
- Orchestrator `upsert_customer(dns, username, ipv6)` above the bare
  client: builds `{username}.{*DOMAIN}` + `*.{username}.{*DOMAIN}`
  (reading the `DOMAIN` global), upserts both concurrently
  (`tokio::join!`), returns the first error. Mirrored `remove_customer`.
- `ControlPlane` gains the `DnsApiClient` (a field, symmetric with the
  WG client) and a `with_dns` constructor. `signup`/`delete` call the
  orchestrator at the right points; signup's DNS write runs **last**
  and is non-fatal (log, don't fail).
- `POST /signup` accepts a body; username validated as a DNS label.
  **The username IS the customer id** (structural uniqueness — the
  Redis key collides, so duplicates are impossible); `Customer`/
  `SignupResponse` gain `username` (replacing `id`) and `hostname`.
- Reconcile loop task spawned in `edge.rs`: reads the customer set
  from Redis, for each verifies `{username}.{*DOMAIN}` AND
  `*.{username}.{*DOMAIN}` via `resolve_aaaa`, re-applies mismatches
  via the orchestrator. First pass ~30s after boot, then ~2h.

Deferred: removing the tofu `dns.tf` customer wildcard and the static
`example123.nix.tftpl` WG/forward wiring (next arc). Apex records stay
in tofu.

## Alternatives considered

- **Tofu renders DNS (status quo)** — case for: already built, one
  source of truth. Case against: it's the wrong layer for runtime
  state — a customer record can't appear/disappear on signup without a
  `tofu apply` per customer. This is the same "tofu holds runtime
  state" anti-pattern that caused the dark boots and that the whole
  control-plane-source-of-truth arc is retiring. Rejected.
- **`DnsApiClient` takes config params / per-instance fields** — case
  for: explicit. Case against: config is immutable process-lifetime
  data; threading zone/token/domain through every call and every struct
  is weight with no payoff. `LazyLock` statics + an inherent
  `from_env()` match the `DOMAIN` global and the edge-globals pattern.
  Rejected.
- **Provider interface holds `initialize_from_env_vars() -> Self` on
  the trait** — case for: uniform construction. Case against: a trait
  method returning `Self` by value can't be called through `dyn` (needs
  `where Self: Sized`), and it pollutes the runtime-operations
  abstraction with a construction concern. `from_env()` as an inherent
  method on `HetznerDns` is cleaner. Rejected.
- **Trait method takes the relative label, client appends domain** —
  case for: less call-site noise. Case against: leaks the `*.` wildcard
  + naming policy into the provider and couples the client to the
  domain. The bare client takes the *full* name; the orchestrator owns
  naming. Rejected (matches the "provider-faithful, one record" goal).
- **`HetznerDns` holds `domain`, or `DNS_ZONE_ID`/`DOMAIN` live as
  separate statics** — case for: fewer globals / one struct. Case
  against: `domain` is naming policy, not provider config — it changes
  for different reasons and belongs in the layer above (the
  orchestrator's `DOMAIN` global), exactly as `WgClient`'s config has
  no naming baked in. Keeping `zone_id`/`token` on `HetznerDns` and
  `DOMAIN` separate keeps the provider dumb about names. Rejected.
- **Reconcile = boot-time upsert-all** — case for: simplest, no read
  API. Case against: a blind write-storm that hammers the provider API
  for every customer on every boot even when nothing changed, and
  never *verifies* the records took effect — "write and hope," exactly
  the silent seam this proposal's strongest objection warns about.
  Rejected.
- **Resolution lives on the API client** — case for: one object. Case
  against: provisioning (Hetzner API) and resolution (querying a
  resolver) are independent concerns with different providers; folding
  resolution into the client would require a client to know how to do
  something it isn't for. `resolve_aaaa` is a free function. Rejected.

## Architecture decisions

Extends ADR-025's "runtime provisioning without disruption": the DNS/
AAAA record API is the third leg (forwarder live mutation + `wg set`
are done). No new ADR. The `DnsApiClient` trait mirrors `WgClient`
(`controlplane/wg.rs`): real shells to an API, mock records calls,
`Send + Sync`, `thiserror` error enum. The global/static-config shape
follows `writing/human/lifetimes_in_rust.md` (immutable process data →
`'static`/`LazyLock`) and the edge-process-globals precedent.

Two new dependencies: `reqwest` (Hetzner DNS API) and
`hickory-resolver` (the resolution/verification function, tokio
feature). The username-as-id follows the principle that a key with no
rename feature should be structural: the customer's identity is its
username, uniqueness is guaranteed by Redis key collision, and there
is no separate `id`↔`username` indirection to maintain.

## Tasks

### T1: ✔ `DnsApiClient` trait + `HetznerDns` + `MockDnsApiClient` (`controlplane/dns.rs`)
**Depends on:** none
**Verification:** `dns_api_*` unit tests — upsert/remove via mock
record the `(name, ipv6)`; `HetznerDns::from_env()` builds from env
**Files:** `src/controlplane/dns.rs` (new), `src/controlplane/mod.rs`
(mod), `Cargo.toml` (add `reqwest`)

### T2: ✔ Static config globals + `get_dns_api()` + `DOMAIN` global
**Depends on:** T1
**Verification:** `HETZNER_DNS_CONFIG`/`get_dns_api() -> &'static dyn
DnsApiClient` resolve from env; `DOMAIN` is a separate `'static` global
(default `interdim.net`); `init_globals` fails fast on missing DNS env
**Files:** `src/controlplane/dns.rs`, `src/controlplane/mod.rs`

### T3: ✔ Resolution `resolve_aaaa` (hickory-resolver, fixed resolver)
**Depends on:** T1
**Verification:** `resolve_aaaa` returns the AAAA set for a name against
1.1.1.1; unit-testable against a mock resolver
**Files:** `src/controlplane/dns.rs`, `Cargo.toml` (add
`hickory-resolver`)

### T4: ✔ Orchestrator `upsert_customer` / `remove_customer`
**Depends on:** T2
**Verification:** unit test asserts both records upserted (main +
wildcard) concurrently; error propagation on failure
**Files:** `src/controlplane/dns.rs`

### T5: ✔ Username-as-id; wire `DnsApiClient` into `ControlPlane`; signup takes a username + returns hostname
**Depends on:** T4
**Verification:** `Customer.id` → `username` (Redis key, delete path,
list); `signup(username)` validates the label, enforces uniqueness,
calls orchestrator last (non-fatal), returns `hostname`; existing
control-plane tests updated
**Files:** `src/controlplane/mod.rs`

### T6: ✔ Hook delete to DNS + reconcile loop (decision fn + spawn)
**Depends on:** T5
**Verification:** `delete` removes records; reconcile decision fn
verifies both records and re-applies mismatches (unit-tested with mock
resolver + mock API); loop spawned in `edge.rs` (30s boot tick, ~2h
interval)
**Files:** `src/controlplane/mod.rs`, `src/controlplane/dns.rs`,
`src/bin/edge.rs`

### T7: ✔ Wire DNS config into `edge.rs` boot + run live round trip
**Depends on:** T6
**Verification:** `cargo test` all green (incl. live Redis round trip
against mock DNS); `cargo build --bins`; `nix flake check` (edge
systemConfig evals)
**Files:** `src/bin/edge.rs`

## Strongest objection

This adds the crate's **first outbound network dependency and first
external-API client**, and it makes signup depend (however tolerantly)
on a live Hetzner DNS API — a service that can be down, rate-limited,
or misconfigured independently of Redis and WireGuard. The non-fatal
signup posture hides this: a signup can "succeed" while its DNS silently
never appears, and if the reconcile loop is not bulletproof, the
customer's hostname 404s while their IP works — a confusing failure the
operator has to notice by hand. The strongest defense is that DNS is
cosmetic to the tunnel (the `/128` works regardless), so the failure
mode is degraded-but-functional, not broken; but that is exactly the
kind of silent seam AGENTS.md calls a bug, and it demands the boot-time
fail-fast (`init_globals` returns `Err` on bad DNS config) plus a
reconcile loop that actually verifies real resolution — both easy to
skip, both obligatory. The risk is that this arc ships a DNS client
that *looks* done but whose reconciliation is untested against a real
Hetzner zone, reintroducing the "works but unproven" debt this project
explicitly forbids.