# Cococoir Technical Plan

**Status:** Living document. Single source of truth for cococoir's technical direction. Update as decisions change; don't let it drift from reality.
**Audience:** Nicole (sole technical). Sales / cofounders can read but the actionable detail is hers.
**Companion to:** `/home/nicole/Documents/untitled-business/writing/plan.md` (the business plan). This plan answers "how do we build it," not "what are we building and why."

---

## Context

Cococoir is a worker cooperative selling pre-configured home servers that replace Big Tech SaaS for non-technical customers. The business plan targets 1000 customers to go full-time. Currently one customer (a nonprofit needing a Google Docs replacement) running on `amon-sul`, a single NixOS home server with a rathole tunnel to a single VPS.

This plan answers: *what do we build, in what order, to make this a product that works at 1000-customer scale?*

### Hard constraints

- **Sole technical person.** Sales, business, and operations are handled by the cofounders; engineering is Nicole. Every workstream competes for the same 1 person. Ruthless prioritization is survival.
- **Performance is BOM-bound.** A $300 box with Orange Pi Zero 3W + 4TB HDD has limited RAM and CPU. No heavy runtimes (JVM, Node clusters). Go and Rust for new code; Nix for everything else.
- **Networking is the differentiator.** The 3-part system (local Caddy + tunnel + DNS) is what makes the box feel like a real SaaS product. Customers see a real FQDN, not an IP.
- **Data is sacred.** Customers store their lives in this thing. Data loss is existential.
- **No Big Tech telemetry.** No Sentry, no Datadog, no SaaS that sees customer data. Self-hosted observability only.
- **TLS never terminates on our infrastructure.** All TLS termination happens on the customer's box (Caddy). The networking layer is a dumb L4 pipe. This is the security model.

### Current state

- v2 lives at `cococoir/` (root). v1 is frozen at `cococoir/v1/`. amon-sul still consumes v1 via `?dir=v1`; the customer (the nonprofit) is on v1.
- v0 build progress:
  - Project skeleton + v1 freeze: **done**
  - Tenant module (3 inputs + derived subdomains): **done**
  - Go edge service (L4 forwarder): **in progress** — Go binary + Nix module + test fixtures written; nixosTest not yet wired
  - PocketID, Garage, Caddy: pending
  - First end-to-end customer-journey test: pending
  - Control plane service: deferred (after v0 ships)
- The current state of cococoir the codebase: piecemeal, v1 frozen, v2 growing. The first migration (v1 → v2) is gated on v0 shipping.

---

## Strategic direction: the v1 → v2 migration

We are doing a **piecemeal migration**, not a rewrite. Concretely:

1. **v1 keeps working.** `amon-sul` and the existing customer stay on v1. v1 gets bug fixes only, no new features.
2. **v2 grows in parallel.** New code in `cococoir/v2/` (sibling to v1). Each piece of v2 is tested, validated, and earns the right to migrate.
3. **v1 is deprecated when v2 is feature-equivalent AND has earned customer trust.** Migration is one flake input change in amon-sul (`?dir=v1` → root).

This is a strangler-fig pattern. v1 code is not deleted; it's moved to `cococoir/v1/` and frozen. v2 is built fresh, informed by v1's lessons, not bound by v1's debt.

### Why piecemeal beats a rewrite

- **Big-bang rewrites ship late and break 500 things at once.** Piecemeal ships small, testable increments. Each step is reversible.
- **v1 still works.** The customer is unaffected while v2 is being built. If v2 stalls, v1 keeps serving.
- **The "rewrite from clean state" cost is paid once at the start, not 500 times over the next year.** Starting clean means we can apply every lesson (4-option contract, base-layer auth, declarative init oneshots) without the friction of refactoring in place.
- **v1 stays as a reference.** When v2 is done, v1's design decisions are documented in the code. New contributors can read v1 to understand "why we used to do X" and "why v2 does Y."

### The 4-week kill criterion

Piecemeal migrations stall. **At the end of week 4, if v2 hasn't reached "tenant + PocketID + Garage + 1 service + OIDC working in a customer-journey VM test," abandon v2 and apply the testing infrastructure to v1 instead.** Better to have tested v1 than untested v2. The test harness is the highest-leverage thing; it benefits v1 even if v2 never ships.

### The v0 goal

Nicole's goal: ship a working v0 (first v2 release, minimum lovable). v0 is defined in the "v0 architecture" section below. The implementation backlog (also below) lists the work in build order. The 2-week number from the original plan was motivation, not a deadline. Realistic v0 is however long the backlog takes.

---

## v0 architecture

The minimum lovable v0 is a system that takes 3 inputs from a customer and produces a working home server with login, file storage, and one or two services. The shape:

```nix
# Customer input (in their sops-encrypted config)
cococoir.tenant.alice = {
  domain = "alice.untitledbusiness.info";          # or alice.theircompany.org (BYO later)
  adminUser = "alice";
  adminPasswordFile = config.sops.secrets."alice-admin".path;
};
```

Cocccoir derives everything else:

```nix
# Derived (cococoir computes these, customer never sets them)
cococoir.tenant.alice.pocketid.domain    = "auth.${cfg.domain}";     # auth.alice.untitledbusiness.info
cococoir.tenant.alice.services.jellyfin.domain = "jellyfin.${cfg.domain}";
cococoir.tenant.alice.services.cryptpad.domain = "cryptpad.${cfg.domain}";
# ... etc, deterministic
```

The customer can:
- (nothing yet — see ADR-011 and ADR-012)

The customer **cannot**:
- Add their own services (cococoir decides what's available)
- Configure service internals (cococoir picks ports, buckets, settings)
- Bring their own domain in v0 (deferred to v1; v0 is hosted-only)
- Override derived values like subdomains or bucket names (cococoir owns the namespace)
- Opt out of individual services (deferred — see ADR-012)

### Components in v0

```
[customer box: Orange Pi + 4TB HDD]
  - NixOS + cococoir/v2
  - PocketID (OIDC provider)
  - Garage (S3 storage)
  - Caddy (TLS terminator + reverse proxy; ACME DNS-01 via Hetzner)
  - WireGuard client (encrypted tunnel to VPS)
  - Services: jellyfin, cryptpad (initial scope)

[VPS in Hetzner]
  - Per-customer IP (alice.untitledbusiness.info → A 1.2.3.4)
  - Go edge service: TCP/UDP forwarder (NO TLS termination)
  - WireGuard server (peers: each customer box)
  - Hetzner DNS (authoritative for untitledbusiness.info)

[public internet]
  - Alice's friends reach jellyfin.alice.untitledbusiness.info
  - DNS resolves to 1.2.3.4
  - TLS handshake happens on customer Caddy (cert is there)
  - Go service is a dumb pipe
```

### The Go service scope (forever)

The Go edge service is a TCP/UDP forwarder. It does not terminate TLS. It does not do ACME. It does not route at L7. The TLS and ACME story is entirely on the customer Caddy. This is the security model and it doesn't change.

The Go service does:
- Listen on a configurable set of IPs/ports
- Authenticate the customer's box via WireGuard (the kernel does this; we just configure wg interfaces)
- Forward TCP and UDP packets to the right WireGuard peer
- Health checks, metrics, journald logs
- Hot-reload config when a new customer is added (no restart)

The Go service does **not**:
- Terminate TLS
- Manage ACME certificates
- Inspect application-layer data
- Make routing decisions based on SNI, Host header, or anything else above L4

This is the entire scope of the Go service, end of story. v0 is v1 is v2. Operational improvements (better observability, more rigorous testing, multi-tenant scaling) over time, but the scope never grows.

### Why "hosted only" for v0

We control the apex (`untitledbusiness.info`, placeholder until the company is named). Customers get `<name>.untitledbusiness.info`. We register the apex, we manage DNS for it, we own the cert story.

**What this gives us:**
- Customers never touch DNS. They plug in the box, sign in, done.
- One cert strategy (wildcard `*.${customerName}.untitledbusiness.info` per customer via ACME DNS-01).
- One billing story (we charge for the box + the hosted domain).
- One onboarding flow (we provision the customer name, the customer is live).

**What this costs us:**
- We register and maintain `untitledbusiness.info`.
- We need DNS API credentials per customer (Hetzner DNS API token in sops).
- We hit Let's Encrypt rate limits (50 certs/week per registered domain).
- The "customer brings their own domain" path is deferred to v1+.

**Rate limit mitigation:**
- For v0 (1-2 customers), rate limits are not a problem.
- For 1000 customers: spread cert issuance across the week (don't onboard 50 customers on Monday); eventually consider a single wildcard `*.untitledbusiness.info` cert (one cert for all, but compromised if any subdomain is compromised). Decision deferred to v1+ when we have data.

### Subdomain convention (v0)

- PocketID: `auth.${domain}` (idiomatic for OIDC; matches the convention used in PocketID's own docs)
- Services: `<serviceName>.${domain}` (e.g. `jellyfin.${domain}`, `cryptpad.${domain}`)
- No path-prefix URLs in v0 (e.g. `theirdomain.net/jellyfin`). Each service is at its own subdomain. Path-prefix routing has issues with WebSockets, OIDC redirects, and service-specific URL expectations; subdomains avoid all of these.

### Why 3 inputs, not "zero config"

Strict "zero config" is impossible — PocketID needs a domain, Garage needs topology, services need bucket assignments. The right model is **"minimum config + validated defaults."** The customer picks 3 things; cococoir picks everything else; the customer can override per-service enable/disable but not service internals.

The way to enforce this in code: cococoir modules *refuse to evaluate* unless the minimum is provided (`cococoir.tenant.<name>.domain != ""`, etc.). The user is forced to provide what's necessary, nothing more.

This is the test that matters: **"given 3 inputs, can the system boot, serve PocketID, and let the customer log in?"** That's the customer-journey test for v0. It catches every "the system doesn't actually work" failure mode.

---

## v1+ architecture: the control plane

v0 ships with `cococoir.tenant.<name>` as a typed submodule in the Nix flake and the customer onboarding workflow is "operator edits a Nix attrset, adds an IP to the VPS, runs `nixos-rebuild`." This works for 1-20 customers. Past that, it doesn't.

The control plane is the piece that replaces "operator edits git" with a real backend. It is the source of truth for customer records, subscriptions, usage, and infrastructure state. Nix is the deployment mechanism (NixOS modules consume the database state via a small config generator).

```
┌─────────────────────────────────────┐         ┌─────────────────────────────────┐
│ Customer Box                        │         │ Cococoir Cloud                  │
│ (Orange Pi + HDD)                   │  WG     │  ┌───────────────────────────┐  │
│                                     │ tunnel  │  │ Go edge service          │  │
│ NixOS + PocketID (OIDC)             │ <─────> │  │ (L4 TCP/UDP forwarder)  │  │ <─ public internet
│ Garage (S3)                         │         │  │ stateless, JSON config  │  │   (per-customer IPv4)
│ Caddy (TLS + reverse proxy)         │         │  └───────────────────────────┘  │
│ WireGuard client                    │         │                                  │
│ Services: jellyfin, cryptpad        │         │  ┌───────────────────────────┐  │
└─────────────────────────────────────┘         │  │ Control plane (v1+)      │  │ <─ operators, customers
                                                │  │ Go service + Postgres    │  │   (web UI, API)
                                                │  │ - customer records       │  │
                                                │  │ - subscriptions          │  │
                                                │  │ - IP provisioning        │  │
                                                │  │ - DNS provisioning       │  │
                                                │  │ - usage tracking         │  │
                                                │  └───────────────────────────┘  │
                                                │                                  │
                                                │  ┌───────────────────────────┐  │
                                                │  │ Nix flake                 │  │
                                                │  │ (deployment mechanism)    │  │
                                                │  │ reads from Postgres       │  │
                                                │  └───────────────────────────┘  │
                                                └──────────────────────────────────┘
```

**Why a database, not git, as the source of truth:** customer onboarding is "click button → new customer" with auto-provisioned IP, DNS, subscription record, and usage quota. That's runtime state that mutates without going through git. The control plane writes to Postgres; a Nix-config-generator reads from Postgres and emits attrsets; NixOS rebuilds on each machine. v0's git workflow is the initial state; v1's control plane owns the state going forward.

**Why Postgres, not MongoDB or Redis:** cococoir's data is naturally relational (customers → machines, customers → subscriptions, customers → usage records). Strong consistency matters (a subscription is active or not — we cannot tolerate eventual consistency). ACID transactions matter (activating a subscription must atomically update the customer record, the subscription record, the quota, and the active machines list). Single-instance Postgres + hot standby handles 1000+ customers trivially. The "B-tree / distributed hashmap" reasoning in the business plan applies to sharded geo-distributed systems, not to single Postgres. If we ever need to scale out, CockroachDB (Postgres-compatible, distributed) is the migration path — not MongoDB.

**Why per-customer IPv4 is the routing primitive:** cococoir's network design has three properties that have to hold:
- (a) Web traffic accessible from a normal browser over IPv4 (some clients are IPv4-only)
- (b) Proxy box doesn't have a dedicated IPv4 per customer
- (c) HTTP/3 encryption, keys on device, proxy doesn't decrypt

(a)+(c) together rule out (b). The proxy cannot demux encrypted traffic to the right customer without per-customer routing primitives. Per-customer IPv4 is the only working answer. The control plane calls the VPS provider's API to allocate IPv4s as customers come online.

**Cluster topology:** per-customer IP per VPS. Each customer is pinned to a single VPS (`cococoir.tenant.<name>.edgeHost`). The Go service on that VPS holds a slice of the customer list. No shared runtime state between VPSes. The Go service is cluster-ready from day 1 (it's stateless — given a config, it just runs). Failover is manual: operator edits `edgeHost`, rebuilds the affected VPSes, updates DNS. WireGuard's built-in endpoint roaming re-handshakes automatically within keepalive cycles.

This is formalized in ADR-013, ADR-014, ADR-015, ADR-016 below.

---

## Implementation backlog

The work, in build order. No dates. Each item: what it produces, what test verifies it. "Done" = shipped, tested, and committed. "In progress" = work started, not yet verified. "Pending" = in the queue, not started. "Deferred" = not on the immediate path; built later when the trigger arrives.

The trigger for moving from "pending" to "in progress" is the previous item shipping. The trigger for moving from "deferred" to "pending" is operator pain at scale (10-20 customers for the control plane, 50-100 for the cluster).

### Project skeleton + v1 freeze — done

- v2 at `cococoir/` root, v1 frozen at `cococoir/v1/`
- amon-sul flake input updated to `?dir=v1`
- `nix flake check` passes on both

### Tenant module — done

- `cococoir.tenant.<name>` typed submodule with 3 inputs
- Derived subdomains (`auth.${domain}`, `<service>.${domain}`)
- L1 (option tree) test evaluates correctly
- L2 (VM boot) test runs a single-tenant NixOS VM

### Go edge service — in progress

Replaces v1's rathole tunnel. Stateless L4 forwarder. Cluster-ready from day 1: no shared state, config-driven, no coordination between VPSes. The customer-side WireGuard credential bootstrap is unsolved (CGNAT story) and is deferred — for v0 the test uses hardcoded keys.

- `nix/packages/edge/`: Go binary, stdlib-only (no external deps)
- `nix/nixos-modules/edge.nix`: minimal systemd module (`enable` + `configFile`)
- `nix/tests/edge/`: 2-VM nixosTest (edge + client over WireGuard)
- Test: `curl http://127.0.0.1:80/` from the edge VM returns the client's HTTP response, proving the L4 forwarder + WireGuard tunnel work end-to-end

What's left in this item:
- `nix/tests/edge/default.nix` — 2-VM nixosTest
- `nix/tests/edge/fixtures/edge.json` — test forwards
- Wire into `nix/tests/default.nix` aggregator
- `nix flake check` to verify

### PocketID module — pending

OIDC provider for the customer's services. Bootstrap the admin user via STATIC_API_KEY + API call (idempotent).

- `nix/nixos-modules/pocketid.nix`: wraps nixpkgs `services.pocket-id`
- `pocketid-secret-init.service`: generates ENCRYPTION_KEY + STATIC_API_KEY on first boot
- `pocketid-admin-init.service`: creates the human admin via API, idempotent
- Test: VM with PocketID, run admin-init, verify admin can log in via API

### Garage module — pending

S3 storage. Per-customer cluster (matches v1). Decide later if shared topology is needed.

- `nix/nixos-modules/garage.nix`: port from v1
- `nix/nixos-modules/garage-bucket-init.nix`: port from v1
- Test: 1-VM garage, write a file, read it back

### Caddy module — pending

TLS terminator on the customer box. ACME DNS-01 via Hetzner DNS. UDP 443 for HTTP/3.

- `nix/nixos-modules/caddy.nix`: enable Caddy, opens UDP 443, ACME DNS-01
- Test: VM with Caddy, request `*.test.example` from Let's Encrypt staging, serve HTTPS

### First end-to-end customer-journey test — pending

The whole thing in one VM, validated by `nix flake check`.

- 1 VM with tenant config + PocketID + Garage + Caddy + 1 service
- Test script: boot, wait for PocketID, run admin-init, log in, make HTTPS request, verify reachable
- `nix flake check` is the single source of truth

### Migrate amon-sul to v2 — pending

Cut over the customer (the nonprofit) from v1 to v2. v1 freezes after this.

- Update amon-sul flake input (remove `?dir=v1`)
- `nixos-rebuild switch`
- Verify: services up, customer can log in, garage data intact
- v1 → v2 service migration: jellyseerr, qbittorrent, autobrr, matrix, mautrix-gmessages, nextcloud, custom (these are services running on v1 today that need to be ported)

### Control plane service — deferred

Replaces "operator edits git + manual Hetzner API calls" with a real backend. Triggered when the operator workflow gets painful at 10-20 customers.

- Go service (1-3 months of one person's work)
- Postgres database (single instance + hot standby)
- HTTP API for customer/operator actions
- Web UI for customers + operators
- Auto-provisions IPv4 on VPS via Hetzner API
- Auto-provisions DNS via Hetzner DNS API
- Tracks per-customer bandwidth (edge service reports periodically)
- Tracks subscription status
- Optional: Stripe integration, self-serve backup management, self-serve multi-machine customers

The control plane is the source of truth. Nix is the deployment mechanism (a Nix-config-generator reads from Postgres and emits attrsets, NixOS rebuilds on each machine). This is the K8s model.

### Cluster expansion — deferred

Multiple VPSes, each holding a slice of customers. Triggered when N > 50-100 customers, or when geographic distribution becomes a hard requirement.

- `cococoir.edge.hosts.<name>` option tree for VPS records
- `cococoir.tenant.<name>.edgeHost` for the assignment
- Per-VPS NixOS configurations, each filtering the tenant list by edgeHost
- Failover: WireGuard endpoint roaming + manual runbook
- Auto-failover: deferred (heartbeat + automatic tenant migration)

### What we are explicitly not building

- A "BYO domain" path. v0-v1 is hosted-only (`*.untitledbusiness.info`). Customer brings their own domain in v1+ if we ever support it.
- Per-tenant service enable/disable. Every customer gets every known service. ADR-012.
- A control plane UI before v0 ships. The control plane is a separate project; building it before the v0 components work would be premature.
- BGP / anycast. Defer until geographic distribution or scale demands it.
- Multi-region. Single region for the foreseeable future.

---

## Decisions made (ADRs)

These are the architectural decisions we've made. Each is final unless explicitly revisited.

### ADR-001: v1 keeps working until v2 is feature-equivalent

**Context:** Two ways to do reliability work: in-place refactor of v1, or build v2 in parallel and migrate.
**Decision:** Build v2 in parallel; v1 freezes at v0's release.
**Consequence:** Two codebases for the duration. v1 gets bug fixes only, not features. Migration is one flake input change.
**Revisit when:** v2 is feature-equivalent to v1 + has earned customer trust.

### ADR-002: v0 is hosted-only (no BYO domain)

**Context:** Customers either bring their own domain (`*.theirdomain.net`) or use a hosted domain (`*.username.untitledbusiness.info`).
**Decision:** v0 supports hosted only. BYO is v1+.
**Consequence:** We own the apex. We manage DNS. We hit Let's Encrypt rate limits. Customers have zero DNS work.
**Revisit when:** Customer feedback demands BYO. Or: 6 months in, hosted is working well enough that BYO is a "nice to have" instead of "must have."

### ADR-003: Hetzner DNS for the hosted apex

**Context:** ACME DNS-01 requires DNS API credentials. Caddy has first-party DNS modules for several providers.
**Decision:** Hetzner DNS. Free with Hetzner Cloud account, libdns-hetzner is first-party, matches the VPS provider.
**Consequence:** Customer sops has a Hetzner DNS API token per customer. Caddy on customer box uses it for ACME challenges.
**Revisit when:** Hetzner has an outage (we'd need a fallback provider).

### ADR-004: STATIC_API_KEY to bootstrap PocketID admin

**Context:** PocketID needs a user, but the user comes from sops. Chicken-and-egg.
**Decision:** Use STATIC_API_KEY (PocketID's "Static API User" admin) to call PocketID's API at boot and create the real human admin. Idempotent. The static key is kept (for further automation) or rotated after admin creation.
**Consequence:** PocketID's `pocketid-secret-init` runs first (generates secrets), then PocketID starts, then `pocketid-admin-init` runs. There's a brief window where the static user has admin scope; we accept this for v0.
**Revisit when:** v0 ships. If a cleaner approach is found (e.g. pre-populated SQLite at image-build time), document it as an alternative.

### ADR-005: Subdomain convention: `auth.${domain}` for PocketID, `<name>.${domain}` for services

**Context:** How do we name subdomains for v0?
**Decision:** `auth.${domain}` for PocketID (idiomatic for OIDC). `<serviceName>.${domain}` for services. No path-prefix URLs in v0.
**Consequence:** Each service is at its own subdomain. Cert issuance is per-subdomain. Caddy on customer box terminates TLS.
**Revisit when:** A service that can't handle subdomains appears (none known at v0).

### ADR-006: Go service scope is TCP/UDP forwarding only

**Context:** What does the Go edge service do?
**Decision:** Forward TCP and UDP packets from VPS IP to customer box via WireGuard. Nothing else. No TLS termination, no ACME, no L7 routing.
**Consequence:** The Go service is forever simple. The Caddy on the customer box owns TLS. The security model is "TLS lives only on the customer's machine."
**Revisit when:** Never. This is the security model.

### ADR-007: TLS never terminates on cococoir infrastructure

**Context:** Where does TLS end?
**Decision:** Only on the customer Caddy. Cococoir's Go service, VPS, and any other component see only encrypted L4 traffic.
**Consequence:** Customers can verify TLS authenticity (the certs are theirs). MITM detection works (compare certs from LAN and WAN, as the business plan describes). No cococoir component has access to plaintext customer data.
**Revisit when:** Never. This is the security model.

### ADR-008: 3-input customer config (domain, adminUser, adminPasswordFile)

**Context:** How much does the customer have to configure?
**Decision:** Three inputs. Everything else is derived. Customer can override per-service enable/disable but not service internals.
**Consequence:** Cococoir modules refuse to evaluate if the minimum is missing. Customer onboarding is "fill in 3 fields."
**Revisit when:** A customer asks for more configurability (probably defer to "BYO" v1+ path).

### ADR-009: Plan A — v1 in subdirectory, v2 at root

**Context:** Where does v2 live?
**Decision:** `cococoir/v1/` for old code, `cococoir/` (root) for v2. amon-sul updates its flake input to `?dir=v1`.
**Consequence:** One repo, two trees. v2 is the "intended future" (at root); v1 is the "current reality" (in subdir). Migration is one URL change.
**Revisit when:** v2 is ready to migrate; v1's `?dir=v1` URL gets dropped from amon-sul.

### ADR-010: v2 does not depend on clan-core

**Context:** v1 uses clan-core for secret generators, service modules, and inventory. Clan is a heavy dependency with its own concepts (vars, machines, services) and a different release cadence than nixpkgs. v2 is a rewrite; the question is whether to keep clan or shed it.
**Decision:** v2's flake does not include `clan-core` as an input. Secrets come from sops-nix (or whatever the deployer chooses) and are passed as `path` values into cococoir options. Service modules are plain NixOS modules; no `clan.service` class.
**Consequence:** Lighter dependency tree. Easier to reason about. We lose clan's per-machine secret generation; sops-nix covers the use case. v1 keeps clan (it works); v2 doesn't take the dependency. If we later want clan's inventory for fleet management, we evaluate that as a separate decision.
**Revisit when:** A real fleet management need appears that sops + NixOS modules don't cover (probably v1+).

### ADR-011: cococoir picks, customer accepts

**Context:** Every configuration option exposed to the customer is a test surface, a documentation burden, and a way to misconfigure. The 3-input model (ADR-008) sets the floor, but a natural temptation is to add "useful" knobs (per-service enable, subdomain overrides, bucket names, port choices).
**Decision:** Cococoir owns everything except the 3 inputs. All subdomains, bucket names, ports, FUSE mountpoints, OIDC client names, etc. are cococoir's choices, declared `readOnly = true` so the customer literally cannot set them. The customer config is the 3 inputs and nothing more (modulo per-service opt-out if/when ADR-012 says so).
**Consequence:** A non-technical customer with a 5-minute debrief can fill out the customer config. Test surface is bounded. Documentation is small. Onboarding is "fill in 3 fields."
**Revisit when:** A real, repeated customer pattern demands a knob (not a one-off). Bring data, not a hypothetical.

### ADR-012: options on request

**Context:** ADR-011 sets the rule for derived values. The next question is about per-service behavior: should the customer be able to opt out of a service (e.g. "alice doesn't want cryptpad")? Should they be able to enable a service not in the default set?
**Decision:** Don't expose `services.<name>.enable` until a real customer asks for it. Every customer gets every known service (v0: jellyfin + cryptpad). Adding a service in v0.1 gives it to every customer — they can opt out only after a real demand appears. Same principle as ADR-011 applied forward in time: don't add the option preemptively.
**Consequence:** Smaller option tree. Customers get the full v0 experience by default. If a customer says "I don't want cryptpad," we add `services.cryptpad.enable` (default true). Until then, no option.
**Revisit when:** A customer asks to turn off a service. At that point, add the option, set default to `true` (opt-out, not opt-in), and ship.

### ADR-013: Nix is the deployment mechanism, not the source of truth

**Context:** Cococoir v2 has Nix configs for each machine (customer box, VPS, edge service). The question is: where does the source of truth for customer records live?

**Decision:** For v0 (1-20 customers), git is the source of truth. Operator edits a Nix attrset, runs `nixos-rebuild`. This is fine for the first stage.

For v1+ (after the control plane ships), the control plane is the source of truth. The control plane writes to Postgres; a Nix-config-generator reads from Postgres and emits attrsets; NixOS rebuilds on each machine. Nix is the deployment mechanism, not the source of truth.

**Consequence:** Two distinct workflows: v0 (git + manual rebuild) and v1+ (control plane + automatic). The transition is "introduce the control plane; treat the existing git state as the initial database."

**Revisit when:** v0 ships and we hit 10-20 customers.

### ADR-014: per-customer IPv4 is required (the "impossible triangle")

**Context:** Three properties the network design has to hold:
- (a) Web traffic accessible from a normal browser over IPv4 (some clients are IPv4-only)
- (b) Proxy box doesn't have a dedicated IPv4 per customer
- (c) HTTP/3 encryption, keys on device, proxy doesn't decrypt

**Decision:** Property (b) is incompatible with (a)+(c). The proxy cannot demux encrypted traffic to the right customer without per-customer routing primitives. Per-customer IPv4 is the only working answer. The proxy box on the VPS has N customer IPs attached, each pinned to a specific customer; incoming traffic to IP X is forwarded to customer X's box over WireGuard.

**Consequence:** Each customer = 1 IPv4 address on the VPS. At 1000 customers we need a /22 or so of IPv4 space, distributed across multiple VPSes. The provisioning system (control plane) calls the VPS provider's API to allocate IPv4s as customers come online. The cluster topology (ADR-016) gives us the per-VPS slice.

**Revisit when:** Never. This is a physical constraint of the protocol design.

### ADR-015: Postgres is the control plane database

**Context:** What database backs the control plane (v1)?

**Decision:** Postgres. Single instance + hot standby + pg_dump/WAL archiving for backups. v1 scale (~1000 customers) is well within single-instance Postgres. Migration path to CockroachDB (Postgres-compatible, distributed SQL) at v2+ if we need to scale out.

**Consequence:** Standard SQL, ACID, joins, indexes. The data model is naturally relational (customers → machines, customers → subscriptions, customers → usage). Don't use Redis or MongoDB as the source of truth. The "B-tree / distributed hashmap" reasoning in the business plan applies to sharded geo-distributed systems, not to single Postgres. If we ever need to scale out, CockroachDB is the migration path — not MongoDB.

**Revisit when:** v2+ if we hit Postgres scaling limits (unlikely for years). Or earlier if we want geo-distributed.

### ADR-016: cluster topology is per-customer IP per VPS, manual failover

**Context:** How do we scale the edge service beyond 1 VPS?

**Decision:** Per-customer IP per VPS. Each customer is pinned to a single VPS (`cococoir.tenant.<name>.edgeHost`). The Go service on that VPS holds a slice of the customer list. No shared runtime state between VPSes. Failover is manual: operator edits `edgeHost`, rebuilds the affected VPSes, updates DNS. WireGuard's built-in endpoint roaming re-handshakes automatically within keepalive cycles.

**Consequence:** The Go service is cluster-ready from day 1 (it's stateless — given a config, it just runs). The cluster story is a Nix option tree (`cococoir.edge.hosts.<name>`) + per-VPS NixOS configurations that filter the tenant list by `edgeHost`. No BGP, no anycast, no shared state. At 1000 customers, this means 50-100 VPSes, each with 10-20 customers (per-customer IP cost ~$1/mo on Hetzner, VPS cost ~$5/mo shared).

**Revisit when:** Operator workflow for manual failover gets painful at 50+ customers (build auto-failover then). Or when geographic distribution becomes a hard requirement (consider anycast).

---

## Design principles

These are the working principles for the v2 codebase. They generalize ADRs 011 and 012 and apply to every option we ever consider adding.

- **Wine-mom config.** A non-technical customer with a 5-minute debrief can fill out the customer config. Every option is a test surface, a doc burden, and a way to misconfigure. Optimize for the 99% case.
- **Cococoir picks.** Cococoir owns the namespace. Subdomains, bucket names, ports, paths, OIDC client names — all cococoir's choice. The customer fills in 3 fields.
- **Options on request.** Don't expose a knob until a real, repeated customer pattern demands it. Default to the most useful behavior. Revisit only with data.
- **Tests are leverage.** The test framework (L1 option tree, L2 VM boot, L3 customer journey) is the highest-leverage artifact in this project. Every module change ships with a test. A test failure is a bug, not a flake.

---

## Decisions still pending

Open questions for the next phases. Flagged so they don't get forgotten; not blockers for v0.

### Pending: control plane feature scope

What does the v1 control plane include? Must-haves:
- Customer onboarding (web form or API)
- IPv4 provisioning (Hetzner API)
- DNS provisioning (Hetzner DNS API)
- Subscription status (manual or Stripe)
- Bandwidth tracking (edge service reports periodically)
- Web UI for customers + operators

Optional / later:
- Stripe integration
- Self-serve backup management
- Self-serve multi-machine customers
- Customer-facing analytics
- Public status page

**Decision criterion:** Build the must-haves first. Add the optional items when customers ask.

### Pending: cluster failover automation

v1: manual runbook. Operator edits `edgeHost`, rebuilds, updates DNS.
v2+: automate. Heartbeat + automatic customer migration.

**Decision criterion:** Defer until manual workflow is painful at 50+ customers.

### Pending: bandwidth tracking implementation

How does the Go edge service report per-customer bandwidth to the control plane?
- Option A: per-customer counter in the Go service, exposed via HTTP API
- Option B: VPS-level network accounting (iptables bytes counter per IP)
- Option C: tcpdump sampling at the VPS level

**Decision criterion:** whichever is least invasive and gives accurate numbers. Likely Option A.

### Pending: subscription billing

v1: manual invoicing (operator generates invoices, customer pays via bank transfer)
v2+: Stripe (or similar) for self-serve

**Decision criterion:** Defer until manual workflow is painful.

### Pending: storage topology at scale

Per-customer Garage (v0) vs shared Garage with quotas (v1+). Defer until we have data on operational cost of per-customer.

### Pending: cert strategy at scale

When 50+ customers, Let's Encrypt rate limits become real. Options:

- Wildcard per customer: `*.alice.untitledbusiness.info`
- Single wildcard for the apex: `*.untitledbusiness.info`
- SAN cert with multiple subdomains

**Decision criterion:** Defer until we have data. The decision is security-model-vs-rate-limit tradeoffs, and we don't have enough customers to know which one bites first.

### Pending: company name

`untitledbusiness.info` is a placeholder. Replace when the cooperative picks a real name. One config option, no other code changes.

(Resolved: clan-core decision is in ADR-010; WireGuard mesh topology is in ADR-016.)

---

## Customer migration path

The customer (the nonprofit, using v1 on amon-sul) and amon-sul itself stay on v1 until v2 has earned the migration. Earned means:

1. v0 ships (when the implementation backlog's pending items are all done and verified).
2. v0 has run on a real box (not just VM tests) for at least 1 week with no critical issues.
3. The customer-journey test continues to pass.
4. Offsite backup works (added in v0.5 or wherever — see risks below).

When v2 is ready:

1. amon-sul flake.nix: change `cococoir.url` from `?dir=v1` to root.
2. `nix flake update cococoir && nixos-rebuild switch`.
3. Verify: all services still up, customer can still log in, garage still has the data.
4. Customer notification: "We upgraded your box's underlying software. You might see a brief downtime during the switch. Nothing on your end changes."

If migration fails, the rollback is: change the URL back, `nix flake update`, `nixos-rebuild switch`. Five minutes. This is why the v1 → v2 split is in two directories instead of in-place refactoring.

### Offsite backup during the migration

This is a v0 risk. v1 has no offsite backup (per the original tech-debt analysis). v2 should add offsite backup *before* the customer migrates to v2, so the customer gets backup as a side effect of the upgrade.

**Recommendation:** Add an "offsite backup" item to the implementation backlog before the customer migration. This is 1-2 days of work. Backup before the customer migrates, not after.

---

## Risks and honest concerns

### Risk: the Go service is the bottleneck

**Severity:** Medium. A working v0 Go service is 2-3 weeks for one person. The "production-grade" version (auth, observability, hot-reload, chaos-tested) is 4-6 weeks.
**Mitigation:** v0 scope is "TCP + UDP forward, validated with 2-VM test." Add operational concerns (auth, metrics, hot-reload) in v0.5 / v1.

### Risk: cert rate limits bite at scale

**Severity:** Low for v0, high at 1000 customers.
**Mitigation:** Spread cert issuance across the week. Plan for single-wildcard `*.untitledbusiness.info` in v1+ if needed.

### Risk: "hosted only" means we own the apex

**Severity:** Medium. If `untitledbusiness.info` has a DNS outage, every customer is down.
**Mitigation:** Use Hetzner DNS's SLA + consider a fallback DNS provider (secondary NS). Defer to v1+.

### Risk: operator workflow doesn't scale past 10-20 customers

**Severity:** Medium. v0 is git + manual operator workflow. At 10-20 customers, the operator (Nicole) hits the wall: "I can't add another customer tonight, I'm behind on X." This is the trigger to build the control plane.
**Mitigation:** Plan for the control plane from the start. Don't pretend manual will scale.

### Risk: control plane is a large project

**Severity:** High. 1-3 months of one person's work. v0 ships before the control plane exists; the control plane is its own milestone. Don't try to build it before v0 ships.
**Mitigation:** Treat the control plane as a separate project. Scope it tightly. Defer the optional features (Stripe, multi-machine self-serve) until the must-haves (customer records, IP provisioning, subscription) are working.

### Risk: data model might need rework as we learn

**Severity:** Medium. The first version of the control plane's data model will get things wrong. Migrations are real.
**Mitigation:** Start small. Add tables as we need them. Postgres handles schema changes well; use migrations from day 1 (even a hand-rolled `ALTER TABLE` script is fine).

### Risk: PostgreSQL single point of failure (until hot standby exists)

**Severity:** Low for v1. Single-instance Postgres is fine; loss of the DB is recoverable from backups.
**Mitigation:** Hot standby from v1 day 1. pg_dump + WAL archiving for offsite backups. Document the recovery procedure.

### Risk: the 4-week kill criterion

**Severity:** Medium-high. If v2 stalls, we need to apply the testing infra to v1 instead.
**Mitigation:** The test harness is built in v2 with the explicit goal of "can be applied to v1." The skeleton task includes a verification step: "the test harness works against v1 modules too."

### Risk: PocketID admin-creation flow is fragile

**Severity:** Medium. The PocketID API for user creation is thin on documentation. The PocketID item in the implementation backlog might stretch.
**Mitigation:** Fallback plan: `signupMode = "withToken"` and have a one-time signup token in sops. Less elegant, but works.

### Risk: customer can't wait

**Severity:** Low. The customer is the nonprofit, and Nicole has a relationship. They're tolerant. The 2-4 week v0 timeline is fine.
**Mitigation:** Keep the customer informed. "We're working on reliability improvements. You might see a brief switch-over in 4-6 weeks."

### Risk: Hetzner has an outage

**Severity:** Low. Hetzner has good uptime. Multi-region is a v1+ concern.
**Mitigation:** Document the runbook for "Hetzner is down, what do we do."

### Risk: the company name placeholder

**Severity:** Trivial. We use `untitledbusiness.info` as a placeholder until the cooperative picks a real name.
**Mitigation:** Make the placeholder easy to change. One config option.

### Risk: I (the AI agent) am not actually doing the work

**Severity:** Real. The plan assumes Nicole is writing code. I'm writing the plan and asking questions. The skeleton + tenant module work shipped because Nicole sat down and did it. The current next action (Go edge service completion) is the next thing Nicole needs to drive.
**Mitigation:** Be honest about who does what. I help with design, code review, debugging, and writing the trickier bits. Nicole does the integration, the testing, the deployment. I don't pretend to be her.

---

## Current next action: complete the Go edge service

What's left to finish the in-progress item in the implementation backlog:

1. `nix/tests/edge/default.nix` — 2-VM nixosTest (edge + client over WireGuard). Edge runs `cococoir-edge` + WireGuard server (wg0 = 10.10.0.1/24). Client runs WireGuard client (wg0 = 10.10.0.2/24) + a `python3 -m http.server 80` listener.
2. `nix/tests/edge/fixtures/edge.json` — the test forwards: TCP 80 → 10.10.0.2:80, TCP 443 → 10.10.0.2:443, UDP 443 → 10.10.0.2:443.
3. Wire into `nix/tests/default.nix` aggregator as `edge-forward` check.
4. `nix flake check` to verify; `nix build .#checks.x86_64-linux.edge-forward --no-link` to run.
5. Update `AGENTS.md` with Day 7-8 status.
6. Clean up the stale `result` symlink at the cococoir root (left over from earlier Day 3-4 manual VM build).
7. Commit, push not required (user directive: "don't push until we have made more progress").

**Verification:** `nix flake check` passes. The `edge-forward` check runs the 2-VM QEMU+KVM test (needs `/dev/kvm`), starts WireGuard on both VMs, starts `cococoir-edge` on the edge VM, and asserts `edge.succeed("curl -sf http://127.0.0.1:80/")` returns the client's HTTP response.

**Why this test design:** the L2 test exercises the full L4-forwarder-over-WireGuard path. `curl http://127.0.0.1:80/` on the edge VM goes: loopback ingress → cococoir-edge (TCP forward) → 10.10.0.2:80 over WireGuard → python httpd on the client → response back through the same path. No per-IP gymnastics needed; v0 binds 0.0.0.0 in the test. Real per-customer-IP binding is exercised by the cluster topology (ADR-016), deferred to v1+.

**What's deliberately out of scope for v0:**
- A `cococoir.edge.hosts.<name>` option tree for multi-VPS clusters. Defer until cluster expansion.
- Per-customer-IP forwarding (each customer = 1 IP, the Go service binds to 0.0.0.0 in the test). Defer to cluster expansion.
- Hot-reload of the edge config (no SIGHUP; `systemd restart` on NixOS rebuild). Defer to v1+ if needed.
- The customer-side WireGuard credential bootstrap (CGNAT story). Hardcoded test keys for now.

**After this:**
- Either: continue with PocketID (the next pending item), or skip to Garage.
- Defer the control plane until v0 ships.
- Eventually: cut over the customer (the nonprofit) from v1 to v2.

---

## Related documents

- `/home/nicole/Documents/untitled-business/writing/plan.md` — the business plan. Why cococoir exists, who it's for, what the market looks like.
- `cococoir/v1/AGENTS.md` — the v1 architecture. Kept for reference; will not be updated.
- `cococoir/v1/PLAN-OLD.md` — the previous version of this document. The Phase 0/1/2/3 plan that the user pivoted away from. Kept for reference.
- `/home/nicole/Documents/amon-sul/AGENTS.md` — the amon-sul deployment. Will need a v2 section once the customer migrates.

---

## Open questions for future ADRs

When these come up, write a new ADR and link it from here. Don't let the open-questions list grow without decisions.

- Storage topology: shared vs per-customer (still open; v0 = per-customer, defer decision).
- The "company name" decision (placeholder `untitledbusiness.info`).
- Multi-region (deferred to v2+; not a v0 blocker).
- Self-service customer onboarding (deferred to v2+; v0-v1 is operator-driven via git / control plane).
- Backup and DR policy (v0.5 / v1).
- Observability stack (v0.5 / v1).
- Runbooks (v0.5 / v1).
- Release discipline (v0.5 / v1).
- Public status page (v1 / v2+).
- Cert strategy at scale (50+ customers).
- Customer-side WireGuard credential bootstrap (CGNAT story; the customer needs to get the WG public key onto their box somehow, and "send them a file" doesn't work if they're behind CGNAT with no inbound access).

Resolved (now in ADRs):
- IPv4 allocation strategy: ADR-014 (per-customer IPv4 required) + ADR-016 (per-VPS cluster).
- Drop clan-core: ADR-010 (v2 doesn't depend on clan-core).
- WireGuard mesh topology: ADR-016 (star with per-customer IP per VPS).
