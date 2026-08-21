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
/signup` creates `*.bob.interdim.net` (+ `bob.interdim.net`) AAAA →
the customer's `/128`, `DELETE` removes them, and boot rehydrates them
from Redis. It introduces the crate's first outbound HTTP dependency
(`reqwest`) and the first Hetzner-DNS-API client. Retiring the static
`dns.tf` wildcard / `example123` path is **deferred** to the next arc
— this is the gate that makes that retirement safe.

## Acceptance criteria

- [ ] `POST /signup` takes a JSON body `{"username":"bob"}` (a valid
      DNS label) and, in addition to today's allocations, creates the
      AAAA records `bob.interdim.net` and `*.bob.interdim.net` →
      the customer's `/128`. The response carries the customer's
      `hostname` (`bob.interdim.net`). (L0: unit test with a mock DNS
      client asserts the two upserts; L2: live box)
- [ ] `DELETE /customers/:id` removes the customer's AAAA records.
      (L0: mock asserts the two removes)
- [ ] Boot `rehydrate` ensures a DNS record exists for every customer
      in Redis (reconcile, not assume). (L0: mock records upserts for
      the rehydrated set)
- [ ] DNS failure does **not** fail a signup: the customer is still
      reachable at their `/128`, and the record self-heals on the next
      rehydrate. (L0: mock DNS that errors → signup still returns 201)
- [ ] A missing/unreachable DNS config fails **at boot**, not on the
      first signup. (L0: `init_globals` returns `Err` when the DNS
      zone/token can't be resolved)
- [ ] The bare `DnsClient` is provider-faithful: one record per call,
      full record name, typed IPv6; the "main + wildcard" policy lives
      above it. (L0: trait shape; no mechanism the customer never feels)

## Smallest version

- `controlplane/dns.rs`: `DnsClient` trait (`upsert_aaaa(name, ipv6)`,
  `remove_aaaa(name)`) + `HetznerDns` (the one real provider) + a
  `MockDnsClient` for tests. `HetznerDns` holds `zone_id`, `token`,
  and an `http: reqwest::Client` — the provider's own config, nothing
  about naming. Constructed by an inherent `HetznerDns::from_env()`
  (static config — env-driven, never changed without a restart).
- `HETZNER_DNS_CONFIG: LazyLock<HetznerDns>` as the single `'static`
  provider config global; `get_dns_config() -> &'static dyn DnsClient`
  hands out the singleton. `HetznerDns::from_env()` fails fast (missing
  env → boot `Err` via `init_globals`).
- `DOMAIN` is a **separate** `'static` `LazyLock<String>` (env
  `COCOCOIR_ROOT_DOMAIN`, default `interdim.net`) — the naming layer,
  above the provider config, owned by the orchestrator, not the DNS
  client.
- Orchestrator `upsert_customer(dns, label, ipv6)` above the bare
  client: builds `label.{*DOMAIN}` + `*.{label}.{*DOMAIN}` (reading the
  `DOMAIN` global), upserts both concurrently (`tokio::join!`), returns
  the first error. Mirrored `remove_customer`.
- `ControlPlane` gains the `DnsClient` (a field, symmetric with the WG
  client) and a `with_dns` constructor. `signup`/`delete`/`rehydrate`
  call the orchestrator at the right points; signup's DNS write runs
  **last** and is non-fatal (log, don't fail).
- `POST /signup` accepts a body; username validated as a DNS label.
  `Customer`/`SignupResponse` gain `hostname`.

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
- **DnsClient takes config params / per-instance fields** — case for:
  explicit. Case against: config is immutable process-lifetime data;
  threading zone/token/domain through every call and every struct is
  weight with no payoff. `LazyLock` statics + an inherent `from_env()`
  match the `DOMAIN` global and the edge-globals pattern. Rejected.
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

## Architecture decisions

Extends ADR-025's "runtime provisioning without disruption": the DNS/
AAAA record API is the third leg (forwarder live mutation + `wg set`
are done). No new ADR. The `DnsClient` trait mirrors `WgClient`
(`controlplane/wg.rs`): real shells to an API, mock records calls,
`Send + Sync`, `thiserror` error enum. The global/static-config shape
follows `writing/human/lifetimes_in_rust.md` (immutable process data →
`'static`/`LazyLock`) and the edge-process-globals precedent.

## Tasks

### T1: `DnsClient` trait + `HetznerDns` + `MockDnsClient` (`controlplane/dns.rs`)
**Depends on:** none
**Verification:** `dns_client_*` unit tests — upsert/remove via mock
record the `(name, ipv6)`; `HetznerDns::from_env()` builds from env
**Files:** `src/controlplane/dns.rs`, `src/controlplane/mod.rs` (mod),
`Cargo.toml` (add `reqwest`)

### T2: Static provider config global + `get_dns_config()` + `DOMAIN` global
**Depends on:** T1
**Verification:** `HETZNER_DNS_CONFIG`/`get_dns_config() -> &'static dyn
DnsClient` resolve from env; `DOMAIN` is a separate `'static` global
(default `interdim.net`); `init_globals` fails fast on missing DNS env
**Files:** `src/controlplane/dns.rs`, `src/controlplane/mod.rs`

### T3: Orchestrator `upsert_customer` / `remove_customer`
**Depends on:** T2
**Verification:** unit test asserts both records upserted (main +
wildcard) concurrently; error propagation on failure
**Files:** `src/controlplane/dns.rs`

### T4: Wire `DnsClient` into `ControlPlane` (`with_dns`); signup takes a username + returns hostname
**Depends on:** T3
**Verification:** `signup` validates username, calls orchestrator last
(non-fatal), returns `hostname`; existing control-plane tests updated
**Files:** `src/controlplane/mod.rs`

### T5: Hook delete + rehydrate to DNS
**Depends on:** T4
**Verification:** `delete` removes records; `rehydrate` reconciles
records for the Redis customer set; mock assertions
**Files:** `src/controlplane/mod.rs`

### T6: Wire DNS config into `edge.rs` boot + run live round trip
**Depends on:** T5
**Verification:** `cargo test` all green (incl. live Redis round trip
against a real/mock DNS); `cargo build --bins`; `nix flake check`
(edge systemConfig evals)
**Files:** `src/bin/edge.rs`

## Strongest objection

This adds the crate's **first outbound network dependency and first
external-API client**, and it makes signup depend (however tolerantly)
on a live Hetzner DNS API — a service that can be down, rate-limited,
or misconfigured independently of Redis and WireGuard. The non-fatal
signup posture hides this: a signup can "succeed" while its DNS silently
never appears, and if the reconcile-on-rehydrate is not bulletproof, the
customer's hostname 404s while their IP works — a confusing failure the
operator has to notice by hand. The strongest defense is that DNS is
cosmetic to the tunnel (the `/128` works regardless), so the failure
mode is degraded-but-functional, not broken; but that is exactly the
kind of silent seam AGENTS.md calls a bug, and it demands the boot-time
fail-fast (`init_globals` returns `Err` on bad DNS config) plus a
rehydrate that actually reconciles — both easy to skip, both obligatory.
The risk is that this arc ships a DNS client that *looks* done but whose
reconciliation is untested against a real Hetzner zone, reintroducing
the "works but unproven" debt this project explicitly forbids.
