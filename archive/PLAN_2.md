# Cococoir Technical Plan (PLAN_2.md)

**Status:** This is the current source of truth for cococoir's technical direction. PLAN.md (the v0 plan) is kept for historical reference but is superseded by this document.
**Audience:** Nicole (sole technical). Sales / cofounders can read but the actionable detail is hers.
**Companion to:** `/home/nicole/Documents/untitled-business/writing/plan.md` (the business plan). This plan answers "how do we build it," not "what are we building and why."

---

## Context

Cococoir is a worker cooperative selling pre-configured home servers that replace Big Tech SaaS for non-technical customers. The business plan targets 300-1000 customers to go full-time. Currently one customer (a nonprofit needing a Google Docs replacement) running on `amon-sul`, a single NixOS home server with a rathole tunnel to a single VPS.

This plan answers: *what do we build, in what order, to make this a product that works at 300-1000-customer scale?*

### Hard constraints

- **Sole technical person.** Sales, business, and operations are handled by the cofounders; engineering is Nicole. Every workstream competes for the same 1 person. Ruthless prioritization is survival.
- **Performance is BOM-bound.** A $300 box with Orange Pi Zero 3W + 4TB HDD has limited RAM and CPU. No heavy runtimes (JVM, Node clusters). Go and Rust for new code; Nix for everything else.
- **Networking is the differentiator.** The 3-part system (local Caddy + tunnel + DNS) is what makes the box feel like a real SaaS product. Customers see a real FQDN, not an IP.
- **Data is sacred.** Customers store their lives in this thing. Data loss is existential.
- **No Big Tech telemetry.** No Sentry, no Datadog, no SaaS that sees customer data. Self-hosted observability only.
- **TLS never terminates on our infrastructure.** All TLS termination happens on the customer's box (Caddy). The networking layer is a dumb L4 pipe. This is the security model and it doesn't change.
- **Wine-mom config.** A non-technical customer with a 5-minute debrief can fill out the customer config. Every option is a test surface, a doc burden, and a way to misconfigure. Optimize for the 99% case.
- **Cococoir picks.** Subdomains, bucket names, ports, OIDC client names — all cococoir's choice. The customer fills in 3 fields.
- **Options on request.** Don't expose a knob until a real, repeated customer pattern demands it. Default to the most useful behavior. Revisit only with data.

### Current state (as of writing)

- v0 lives at `cococoir/` (root). v1 is frozen at `cococoir/v1/`. amon-sul still consumes v1 via `?dir=v1`; the customer (the nonprofit) is on v1.
- **v0 — DONE.** 2-VM nixosTest that exercises the full L4-forwarder-over-WireGuard path. Two binaries (`cococoir-edge` on the VPS, `cococoir-client` on the customer box), each with its own NixOS module and systemd unit. WireGuard between them, with a control channel for v0.5.
- **v0.5 — queued.** Four-PR series that grows the Go service from "dumb forwarder" into the spine of the cococoir cloud (provisioning, admin API, probes). See the implementation backlog.
- **v1 — deferred.** Control plane service (Postgres + web UI) for when the operator workflow hits pain at 10-20 customers.
- The current state of cococoir the codebase: v0 data path is real and tested, v0.5 is the next two weeks of work, v1 is on the shelf.

---

## Strategic direction: the v1 → v2 migration

We are doing a **piecemeal migration**, not a rewrite. Concretely:

1. **v1 keeps working.** `amon-sul` and the existing customer stay on v1. v1 gets bug fixes only, no new features.
2. **v2 grows in parallel.** New code in `cococoir/` (root). Each piece of v2 is tested, validated, and earns the right to migrate.
3. **v1 is deprecated when v2 is feature-equivalent AND has earned customer trust.** Migration is one flake input change in amon-sul (`?dir=v1` → root).

This is a strangler-fig pattern. v1 code is not deleted; it's moved to `cococoir/v1/` and frozen. v2 is built fresh, informed by v1's lessons, not bound by v1's debt.

### Why piecemeal beats a rewrite

- **Big-bang rewrites ship late and break 500 things at once.** Piecemeal ships small, testable increments. Each step is reversible.
- **v1 still works.** The customer is unaffected while v2 is being built. If v2 stalls, v1 keeps serving.
- **The "rewrite from clean state" cost is paid once at the start, not 500 times over the next year.** Starting clean means we can apply every lesson (4-option contract, base-layer auth, declarative init oneshots) without the friction of refactoring in place.
- **v1 stays as a reference.** When v2 is done, v1's design decisions are documented in the code. New contributors can read v1 to understand "why we used to do X" and "why v2 does Y."

### The 4-week kill criterion

Piecemeal migrations stall. **At the end of week 4 of v0.5, if v0.5 hasn't reached "edge + Hetzner IP provisioning + admin API + 1 customer in a customer-journey VM test," abandon v0.5 and reapply the testing infrastructure to v1 instead.** Better to have tested v1 than half-built v2. The test harness is the highest-leverage thing; it benefits v1 even if v0.5 never ships.

v0 itself has already passed its kill criterion (data path tested end-to-end via the 2-VM nixosTest).

---

## v0 architecture (just shipped)

The minimum viable cococoir v0 is two binaries that bridge a public listener on a VPS to a local listener on a customer box, over WireGuard. The shape:

```nix
# On the customer box (NixOS + cococoir v2)
cococoir.tenant.alice = {
  domain = "alice.untitledbusiness.info";
  adminUser = "alice";
  adminPasswordFile = config.sops.secrets."alice-admin".path;
};
```

Cococoir derives everything else (subdomains, bucket names, service lists). The customer's *configuration* of the box is the 3 inputs. Provisioning (allocating the IP, registering DNS, configuring the WireGuard peer) is an operator task in v0 — the operator edits git and runs `nixos-rebuild` on both sides.

### Components in v0

```
[customer box: Orange Pi + 4TB HDD]
  - NixOS + cococoir v2
  - cococoir-client (L4 forwarder; receives WG traffic, forwards to 127.0.0.1:<port>)
  - WireGuard client (encrypted tunnel to VPS)
  - Local Caddy (TLS + reverse proxy; will land in v0.5)

[VPS in Hetzner]
  - cococoir-edge (L4 forwarder; public listener, WG server, forwards to client box)
  - WireGuard server (peers: each customer box)
  - Hetzner DNS (authoritative for untitledbusiness.info)

[public internet]
  - Alice's friends reach jellyfin.alice.untitledbusiness.info
  - DNS resolves to <VPS public IP> (single IP in v0, per-customer IP in v0.5)
  - TLS handshake happens on customer Caddy (cert is there)
  - cococoir-edge is a dumb L4 pipe
```

### The Go service scope (v0, two binaries)

**`cococoir-edge`** (VPS) — listens on a configurable set of public IPs/ports, authenticates the customer's box via WireGuard (the kernel does this; we just configure `wg` interfaces), forwards TCP and UDP packets to the right WireGuard peer. Journald logs.

**`cococoir-client`** (customer box) — receives traffic from the WireGuard tunnel, forwards to `127.0.0.1:<port>` where local Caddy terminates TLS. Journald logs.

Both binaries are **L4 only on the data path.** No TLS termination, no ACME, no L7 routing. The Caddy on the customer's box owns TLS. This is the security model and it doesn't change.

What the v0 binaries do:
- Listen on a configurable set of addresses/ports (read from a JSON config)
- Authenticate via WireGuard (kernel-handled)
- Forward TCP and UDP packets
- Log to journald

What they do **not** do (v0):
- Terminate TLS
- Manage ACME certificates
- Inspect application-layer data
- Make routing decisions based on SNI, Host header, or anything above L4
- Auto-provision IPs (operator does this in v0)
- Run probes (added in v0.5)
- Expose an admin API (added in v0.5)

### Why two binaries, not one

The user pushed back on "one binary does it all" early in the v0.5 design session. The argument: from day 1, the box has to be globally accessible, which means the VPS has to receive public traffic and forward it to the box over the tunnel. That's a *different role* from the box receiving tunnel traffic and forwarding to local services. Two roles → two binaries. They share a forwarder (refactored into a shared Go package in v0.5 PR 1) but they're independently deployed, configured, and updated.

### The control channel (skeleton in v0, filled in for v0.5)

The two binaries need to talk to each other for things that aren't L4 data: probe results, status, configuration, alerts. v0 has the wire in place (same WireGuard tunnel, separate port), but no protocol yet. v0.5 PR 4 fills it in: HTTP/JSON over the tunnel, bearer-token auth (token in sops), `cococoir-client` POSTs probe results and status, `cococoir-edge` exposes the admin API for the operator.

### Config generation: Nix → JSON, secrets via sops

Configs (`edge.json`, `client.json`) are generated from Nix attrs at activation time. The standard pattern is:

```nix
environment.etc."cococoir-edge.json".text = builtins.toJSON {
  forwards = [
    { listen_addr = "0.0.0.0:80"; proto = "tcp"; dest_addr = "10.10.0.2:80"; }
    # ...
  ];
};
```

For configs that need secrets (none in v0; Hetzner API token enters in v0.5), use `sops-nix`'s `sops.templates`:

```nix
sops.templates."cococoir-edge.json" = {
  content = builtins.toJSON {
    forwards = [...];
    hetzner_api_token_path = config.sops.secrets.hetzner.path;
  };
  mode = "0400";
  owner = "cococoir";
};
```

The module's `configFile` option defaults to `/etc/cococoir-{edge,client}.json` (the standard `environment.etc` path), so most operators don't override it. Operators who already have a JSON file in their dotfiles can still point `configFile` at it.

### Subdomain convention (v0)

- PocketID: `auth.${domain}` (idiomatic for OIDC; matches PocketID's own docs)
- Services: `<serviceName>.${domain}` (e.g. `jellyfin.${domain}`, `cryptpad.${domain}`)
- No path-prefix URLs in v0. Each service is at its own subdomain.

### The 2-VM nixosTest (v0 verification)

`nix/tests/edge/default.nix` is the proof that v0 works. Two VMs (`edge` and `client`) joined by a WireGuard tunnel, with `cococoir-edge` running on the edge and `cococoir-client` running on the client. A `python3 -m http.server` on the client plays the role of local Caddy. The test script:

1. Waits for both VMs to reach `multi-user.target`
2. Waits for both WireGuard interfaces to come up
3. Waits for both cococoir services to start
4. Sanity-checks: python is serving, ping works over WG
5. **The test:** `edge.succeed("curl -sf http://127.0.0.1:80/")` — from inside the edge VM, the curl hits the local cococoir-edge listener, which forwards over WG to the client, which forwards to local python. The HTML body contains a known string; that's the assertion.

If this test passes, the data path works. This is the v0 gate.

---

## v0.5 architecture: the spine expands

The v0 Go service is two dumb forwarders. v0.5 grows it into the **spine of the cococoir cloud** — the piece that operator tooling, customer tooling, and reliability monitoring all plug into. The shape of the growth:

| Concern | v0 | v0.5 |
|---|---|---|
| L4 forwarder | yes | yes (refactored into shared package) |
| Per-customer IP binding | no | yes (per-IP listener pattern) |
| Hetzner IP provisioning | no | yes (Hetzner Cloud API client) |
| Hetzner DNS provisioning | no | yes (Hetzner DNS API client) |
| Customer records | Nix git | per-VPS bbolt, populated by admin API |
| Admin API | no | yes (POST /customers, etc.) |
| Local probes (customer box) | no | yes (HTTP GETs to local services) |
| Probe result reporting | no | yes (POST to edge) |
| "Main node" collector | n/a | n/a (folded into edge) |
| Control channel | no (wire only) | yes (HTTP/JSON, bearer-token auth) |
| WireGuard config | operator-wired | operator-wired (still; see "pending" below) |
| TLS on data path | never | never |

**Why this lives in v0.5 and not v1:** the operator pain threshold for the control plane is "I have 10-20 customers and `nixos-rebuild` on each one is taking all my time." v0.5 makes the operator workflow 1 API call per customer instead of N file edits. v1's full Postgres+UI is a bigger project that should be built on a tested spine, not a free-standing rewrite.

### v0.5 PR breakdown

**PR 1: Forwarder growth (week 1).**
- Consolidate `nix/packages/edge/` and `nix/packages/client/` into a single Go module with `internal/forwarder/` shared code. Two `cmd/` entry points (`cmd/edge/`, `cmd/client/`) build two binaries. The 225-line forwarder duplication is gone.
- Add per-IP binding: a forward can specify which local interface to listen on. The forwarder resolves the interface's IP at startup.
- Better signal handling: graceful shutdown closes all listeners, waits for in-flight connections to drain.
- Update the 2-VM nixosTest to cover the per-IP binding case (test binds 192.168.1.10 instead of 0.0.0.0 on the edge).
- Tests: unit tests for the listener registry; integration test still passes.

**PR 2: Hetzner client + bbolt + provisioning (week 2).**
- Add `nix/packages/edge/provision/` package: idempotent Hetzner Cloud API client (allocate/release IP, list servers) and Hetzner DNS API client (add/remove records).
- Add `nix/packages/edge/store/` package: bbolt-based customer record store. One bbolt file per VPS at `/var/lib/cococoir/edge.db`. Schema: bucket `customers` (key = name, value = JSON record with domain, allocated IP, DNS records, WireGuard public key, probe targets).
- Add `cococoir-edge provision` subcommand: takes a customer name, allocates an IP, registers DNS records, writes a customer record to bbolt. Idempotent — safe to re-run.
- Add `pkgs.bbolt` (or `pkgs.cococoir-edge` updated to import bbolt) as a build input.
- Tests: unit tests for the bbolt store (in-memory bbolt, no real I/O); Hetzner client tests use a mock HTTP server (no real Hetzner calls in CI).

**PR 3: Admin API + bbolt CRUD (week 3).**
- Add `nix/packages/edge/admin/` package: HTTP server with `POST /customers`, `DELETE /customers/{name}`, `GET /customers`, `GET /customers/{name}`, `GET /customers/{name}/status`.
- The `POST /customers` endpoint calls the Hetzner client (PR 2) to allocate the IP and DNS, then writes the record to bbolt.
- The `DELETE /customers/{name}` endpoint releases the IP and DNS, then deletes the record.
- Auth: bearer token in sops, bound to the WireGuard interface (defense in depth — public interface rejects, even if the token leaks).
- Wire the admin API into `cococoir-edge`'s main systemd unit.
- Add `nixosTests.environment.etc."cococoir-edge-token"` for the test.
- Tests: integration test for the full add-customer flow with a mocked Hetzner client.

**PR 4: cococoir-client probes + control channel + collector (week 4).**
- Add `nix/packages/client/probe/` package: HTTP GET prober, periodic execution, results stored in a small embedded struct.
- Add `nix/packages/client/control/` package: HTTP client (POSTs probe results + status to `cococoir-edge`).
- Update `cococoir-client`'s main to start the prober on a timer (default: every 60s) and the control client.
- Add `nix/packages/edge/collector/` package: receives POSTs from `cococoir-client`, stores in a `probes` bucket in the same bbolt file.
- Extend the admin API: `GET /customers/{name}/probes` returns the most recent N probe results.
- Add a 3-VM nixosTest: edge + customer box (with cococoir-client) + a "service" (the python http server). Test script: wait for the customer box to probe the service, then verify the edge received the result and the admin API returns it.
- This PR is the **4-week kill criterion** trigger: if it doesn't land, we fall back to v1 + new tests.

### What v0.5 deliberately does NOT do

- A web UI. The admin API is HTTP/JSON; humans use `curl` (or a thin CLI wrapper in v1+).
- Stripe integration. Subscription billing is operator-driven in v0.5 (invoice by hand).
- Self-serve customer onboarding. Operators add customers via the admin API in v0.5.
- WireGuard config ownership. The operator still wires `networking.wireguard.interfaces.wg0` directly. Cococoir owns it in v1+ (when the credential-bootstrap story is solved — see "Pending" below).
- Per-customer IPv4 *allocation* via Hetzner (PR 2 does allocate, but v0.5 uses a single VPS, single /24. Per-customer-IP-per-VPS is v2.)
- Offsite backup. The original PLAN.md recommended this before the customer migrates, but the user (Nicole) decided to skip it: "Skip entirely — not on the v0 path." Backup is a real risk but not on the v0.5 critical path. Revisit after v0.5 ships.

### Customer config flow in v0.5

The customer box's *local* config (services to probe, collector endpoint) is a NixOS module on the customer box, not pushed from the edge. This keeps the customer box's config in git (Nix-as-source-of-truth, ADR-013) and avoids the "what if the edge is down" problem. The edge doesn't push to the box; the box pulls its own Nix config at rebuild time.

```nix
# On the customer box (NixOS config)
cococoir.client.probeTargets = [
  "http://127.0.0.1:8096"   # jellyfin
  "http://127.0.0.1:3000"   # cryptpad
];
cococoir.client.collectorEndpoint = "https://10.10.0.1:9090";  # edge's collector
```

The customer box sends probe results to this endpoint over the WireGuard tunnel.

### Probe system: on the box, not on the edge

Probes run on the *customer box*, not the edge. The box is the source of truth for "is my stuff working?" — local probes are direct (no DNS, no cert, no CGNAT confounders). The edge can do its own public probes as a complement, but the primary signal is local. This is the "edge device has reliability infrastructure that doesn't depend on an external service" property from the business plan: even if our entire cloud is down, the customer's box knows whether its own services are up.

Results are JSON: `{"customer": "alice", "target": "http://127.0.0.1:8096", "status": "up", "latency_ms": 23, "ts": "..."}`. They're POSTed to the edge, which stores them in bbolt. The admin API exposes them. The "main node" / data-warehouse question is deferred to v1: for v0.5, bbolt is enough; the operator can `jq` the export or query the admin API.

### Admin API auth: API token + WireGuard listener

The admin API listens on the WireGuard interface only. Even if the bearer token (in sops) leaks, the API isn't reachable from the public internet. This is "defense in depth" — the token is a second factor, not the only factor. The token is rotated via Nix rebuild (no runtime token-rotation protocol in v0.5; v1 adds it).

The operator's workflow:
1. SSH into the VPS over the operator's own WireGuard tunnel (or via a separate ops tunnel).
2. `curl -H "Authorization: Bearer $COCOCOIR_TOKEN" https://10.10.0.1:9090/customers` to query.
3. `curl -X POST -H "Authorization: Bearer $COCOCOIR_TOKEN" -d @customer.json https://10.10.0.1:9090/customers` to add.

In v0.5, this is `curl` only. v1 adds a CLI wrapper and (later) a web UI.

---

## v1 architecture: the control plane

v0.5 ships with `cococoir.tenant.<name>` as a typed submodule in the customer box's Nix flake and customer onboarding is "operator calls the admin API, runs `nixos-rebuild` on the customer box." This works for 1-20 customers. Past that, it doesn't — the operator is manually editing git, manually running rebuilds, manually tracking who's paid and who hasn't.

The control plane is the piece that replaces "operator edits git" with a real backend. It is the source of truth for customer records, subscriptions, usage, and infrastructure state. Nix is the deployment mechanism (a Nix-config-generator reads from the database and emits attrsets; NixOS rebuilds on each machine).

```
┌─────────────────────────────────────┐         ┌─────────────────────────────────┐
│ Customer Box                        │         │ Cococoir Cloud                  │
│ (Orange Pi + HDD)                   │  WG     │  ┌───────────────────────────┐  │
│                                     │ tunnel  │  │ cococoir-edge (the spine)│  │
│ NixOS + PocketID (OIDC)             │ <─────> │  │ - L4 forwarder           │  │
│ Garage (S3)                         │         │  │ - Hetzner client         │  │
│ Caddy (TLS + reverse proxy)         │         │  │ - admin API              │  │ <─ operators (curl/CLI)
│ cococoir-client (forward + probe)   │         │  │ - probe collector        │  │
│ WireGuard client                    │         │  │ - bbolt store            │  │
│ Services: jellyfin, cryptpad        │         │  └───────────────────────────┘  │
└─────────────────────────────────────┘         │                                  │
                                                │  ┌───────────────────────────┐  │
                                                │  │ Control plane (v1)        │  │ <─ operators, customers
                                                │  │ Go service + Postgres     │  │   (web UI, API)
                                                │  │ - customer records        │  │
                                                │  │ - subscriptions           │  │
                                                │  │ - IP/DNS provisioning     │  │
                                                │  │ - usage tracking          │  │
                                                │  │ - web UI                  │  │
                                                │  └───────────────────────────┘  │
                                                │                                  │
                                                │  ┌───────────────────────────┐  │
                                                │  │ Nix flake (deployment)    │  │
                                                │  │ reads from Postgres       │  │
                                                │  │ generates attrsets        │  │
                                                │  └───────────────────────────┘  │
                                                └──────────────────────────────────┘
```

**Why a database, not git, as the source of truth:** customer onboarding is "click button → new customer" with auto-provisioned IP, DNS, subscription record, and usage quota. That's runtime state that mutates without going through git. The control plane writes to Postgres; a Nix-config-generator reads from Postgres and emits attrsets; NixOS rebuilds on each machine. v0.5's git + bbolt workflow is the initial state; v1's control plane owns the state going forward.

**Why Postgres, not MongoDB or Redis:** cococoir's data is naturally relational (customers → machines, customers → subscriptions, customers → usage records). Strong consistency matters (a subscription is active or not — we cannot tolerate eventual consistency). ACID transactions matter (activating a subscription must atomically update the customer record, the subscription record, the quota, and the active machines list). Single-instance Postgres + hot standby handles 1000+ customers trivially. The "B-tree / distributed hashmap" reasoning in the business plan applies to sharded geo-distributed systems, not to single Postgres. If we ever need to scale out, CockroachDB (Postgres-compatible, distributed) is the migration path — not MongoDB.

**Why per-customer IPv4 is the routing primitive:** cococoir's network design has three properties that have to hold:
- (a) Web traffic accessible from a normal browser over IPv4 (some clients are IPv4-only)
- (b) Proxy box doesn't have a dedicated IPv4 per customer
- (c) HTTP/3 encryption, keys on device, proxy doesn't decrypt

(a)+(c) together rule out (b). The proxy cannot demux encrypted traffic to the right customer without per-customer routing primitives. Per-customer IPv4 is the only working answer. The control plane calls the VPS provider's API to allocate IPv4s as customers come online.

**Cluster topology:** per-customer IP per VPS. Each customer is pinned to a single VPS (`cococoir.tenant.<name>.edgeHost`). The cococoir-edge on that VPS holds a slice of the customer list. No shared runtime state between VPSes. cococoir-edge is cluster-ready from day 1 (it's stateless — given a config, it just runs). Failover is manual: operator edits `edgeHost`, rebuilds the affected VPSes, updates DNS. WireGuard's built-in endpoint roaming re-handshakes automatically within keepalive cycles.

This is formalized in ADR-013, ADR-014, ADR-015, ADR-016, ADR-017 below.

---

## Implementation backlog

The work, in build order. No dates. Each item: what it produces, what test verifies it. "Done" = shipped, tested, and committed. "In progress" = work started, not yet verified. "Pending" = in the queue, not started. "Deferred" = not on the immediate path; built later when the trigger arrives.

### Project skeleton + v1 freeze — done

- v2 at `cococoir/` root, v1 frozen at `cococoir/v1/`
- amon-sul flake input updated to `?dir=v1`
- `nix flake check` passes on both

### Tenant module — done

- `cococoir.tenant.<name>` typed submodule with 3 inputs
- Derived subdomains (`auth.${domain}`, `<service>.${domain}`)
- L1 (option tree) test evaluates correctly
- L2 (VM boot) test runs a single-tenant NixOS VM

### Go edge service (v0 data path) — done

Two binaries (`cococoir-edge`, `cococoir-client`), each with its own NixOS module and JSON config. 2-VM nixosTest exercises the full L4-forwarder-over-WireGuard path: `curl → cococoir-edge :80 → WG → cococoir-client :80 → python :80`. Test passes. Configs generated via `environment.etc` + `builtins.toJSON`. v0.5 PR 1 will refactor the duplicated forwarder code into a shared `internal/forwarder/` package.

### v0.5 PR 1: forwarder growth — pending

- Consolidate `nix/packages/edge/` and `nix/packages/client/` into one Go module with `internal/forwarder/` shared code
- Per-IP binding pattern (a forward specifies which local interface to listen on)
- Better signal handling (graceful shutdown, in-flight drain)
- 2-VM nixosTest updated to cover per-IP binding
- Unit tests for the listener registry

### v0.5 PR 2: Hetzner client + bbolt + provisioning — pending

- `internal/provision/` package: Hetzner Cloud API client (IP allocate/release, server list) + Hetzner DNS API client (record add/remove). Idempotent.
- `internal/store/` package: bbolt-based customer record store. One file per VPS at `/var/lib/cococoir/edge.db`. Bucket `customers`, schema-as-JSON-values.
- `cococoir-edge provision <customer-name>` subcommand: allocates IP, registers DNS, writes record. Idempotent.
- Unit tests with in-memory bbolt and a mock Hetzner HTTP server.

### v0.5 PR 3: admin API + bbolt CRUD — pending

- `internal/admin/` package: HTTP server with `POST /customers`, `DELETE /customers/{name}`, `GET /customers`, `GET /customers/{name}`, `GET /customers/{name}/status`.
- `POST /customers` calls the Hetzner client to allocate IP and DNS, then writes the record to bbolt.
- Auth: bearer token in sops, listener bound to the WireGuard interface only.
- Integration test for the full add-customer flow with a mocked Hetzner client.

### v0.5 PR 4: cococoir-client probes + control channel + collector — pending

- `internal/probe/` package on the client: HTTP GET prober, periodic execution, results stored in memory.
- `internal/control/` package on the client: HTTP client that POSTs probe results + status to the edge.
- `internal/collector/` package on the edge: receives POSTs, stores in `probes` bucket.
- Admin API extension: `GET /customers/{name}/probes` returns recent results.
- 3-VM nixosTest: edge + customer box + service. Verifies probe results flow box → edge → admin API.
- **This PR is the 4-week kill criterion trigger.** If it doesn't ship in 4 weeks of v0.5 start, fall back to v1 + new tests.

### Customer journey test — pending

The whole v0.5 in one VM (per the original PLAN.md's "first end-to-end customer-journey test"). Actually, the 3-VM nixosTest in PR 4 already covers most of this; the customer-journey test is a thin "all 4 PRs together" regression test that runs the full flow.

### Migrate amon-sul to v2 — pending

Cut over the customer (the nonprofit) from v1 to v2. v1 freezes after this.

- Update amon-sul flake input (remove `?dir=v1`)
- `nixos-rebuild switch`
- Verify: services up, customer can log in, garage data intact
- v1 → v2 service migration: jellyseerr, qbittorrent, autobrr, matrix, mautrix-gmessages, nextcloud, custom (these are services running on v1 today that need to be ported)

### Control plane service (v1) — deferred

Replaces "operator edits git + manual Hetzner API calls" with a real backend. Triggered when the operator workflow gets painful at 10-20 customers.

- Go service (1-3 months of one person's work)
- Postgres database (single instance + hot standby)
- HTTP API for customer/operator actions
- Web UI for customers + operators
- Reads from bbolt files (v0.5 store) as the seed data; bbolt migrates to Postgres.
- Auto-provisions IPv4 on VPS via Hetzner API (cococoir-edge already does this in v0.5; the control plane orchestrates it)
- Auto-provisions DNS via Hetzner DNS API
- Tracks per-customer bandwidth (cococoir-edge reports periodically)
- Tracks subscription status
- Optional: Stripe integration, self-serve backup management, self-serve multi-machine customers

The control plane is the source of truth. Nix is the deployment mechanism (a Nix-config-generator reads from Postgres and emits attrsets; NixOS rebuilds on each machine). This is the K8s model.

### Cluster expansion (v2) — deferred

Multiple VPSes, each holding a slice of customers. Triggered when N > 50-100 customers, or when geographic distribution becomes a hard requirement.

- `cococoir.edge.hosts.<name>` option tree for VPS records
- `cococoir.tenant.<name>.edgeHost` for the assignment
- Per-VPS NixOS configurations, each filtering the tenant list by edgeHost
- Failover: WireGuard endpoint roaming + manual runbook
- Auto-failover: deferred (heartbeat + automatic tenant migration)

### What we are explicitly not building

- A "BYO domain" path. v0-v1 is hosted-only (`*.untitledbusiness.info`). Customer brings their own domain in v1+ if we ever support it.
- Per-tenant service enable/disable. Every customer gets every known service. ADR-012.
- A control plane UI before v0.5 ships. The control plane is a separate project; building it before the v0.5 components work would be premature.
- BGP / anycast. Defer until geographic distribution or scale demands it.
- Multi-region. Single region for the foreseeable future.
- Offsite backup before the customer migrates. The original PLAN.md recommended this; the user (Nicole) decided to skip it. Backup is real risk but not on the v0.5 critical path. Revisit after v0.5 ships; if we ship without backup, document the data-loss risk prominently and decide then.
- Web UI for the admin API in v0.5. Operators use `curl` (or a thin CLI wrapper in v1).

---

## Decisions made (ADRs)

These are the architectural decisions we've made. Each is final unless explicitly revisited.

### ADR-001: v1 keeps working until v2 is feature-equivalent

**Context:** Two ways to do reliability work: in-place refactor of v1, or build v2 in parallel and migrate.
**Decision:** Build v2 in parallel; v1 freezes at v0.5's release.
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

### ADR-006: Go service data path is L4 only (REWRITTEN — was "L4 forwarding only, end of story")

**Context:** Original ADR-006 said the Go service is "TCP/UDP forwarding only" and "end of story" (never grows). After v0.5 planning, that's wrong: the Go service grows into the spine (provisioning, admin API, probes). But the *spirit* of ADR-006 is right and must be preserved: the data path is L4, no TLS termination, no L7 routing.
**Decision:** The Go service is L4 only on the **data path**. The control surface (admin API, metrics, Hetzner client, probe collector) is in scope and grows over time. TLS still never terminates on cococoir infrastructure. The forwarder itself remains a dumb L4 pipe; it doesn't grow smarter.
**Consequence:** The forwarder is forever simple (~225 lines, refactored to ~300 in v0.5 PR 1). The Caddy on the customer box owns TLS. The security model is "TLS lives only on the customer's machine." Control-surface code is bounded by the spine scope in ADR-017, not by the data-path simplicity.
**Revisit when:** Never on the data path. Control surface revisits per ADR-017's scope rules.

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

**Decision:** For v0 and v0.5, git + per-VPS bbolt. Operator edits a Nix attrset, runs `nixos-rebuild` on each side. The admin API (v0.5) writes to bbolt on the edge; the customer box's Nix config is git-managed.

For v1, the control plane is the source of truth. The control plane writes to Postgres; a Nix-config-generator reads from Postgres and emits attrsets; NixOS rebuilds on each machine. Nix is the deployment mechanism, not the source of truth.

**Consequence:** Three distinct workflows over time: v0 (git + manual rebuild on both sides), v0.5 (git on the box + admin API on the VPS), v1+ (control plane + automatic). The transitions are "introduce the admin API" and then "introduce the control plane; treat the existing bbolt + git state as the seed database."
**Revisit when:** v0.5 ships and we hit 10-20 customers.

### ADR-014: per-customer IPv4 is required (the "impossible triangle")

**Context:** Three properties the network design has to hold:
- (a) Web traffic accessible from a normal browser over IPv4 (some clients are IPv4-only)
- (b) Proxy box doesn't have a dedicated IPv4 per customer
- (c) HTTP/3 encryption, keys on device, proxy doesn't decrypt

**Decision:** Property (b) is incompatible with (a)+(c). The proxy cannot demux encrypted traffic to the right customer without per-customer routing primitives. Per-customer IPv4 is the only working answer. The proxy box on the VPS has N customer IPs attached, each pinned to a specific customer; incoming traffic to IP X is forwarded to customer X's box over WireGuard.

**Consequence:** Each customer = 1 IPv4 address on the VPS. At 1000 customers we need a /22 or so of IPv4 space, distributed across multiple VPSes. The provisioning system (admin API in v0.5, control plane in v1) calls the VPS provider's API to allocate IPv4s as customers come online. The cluster topology (ADR-016) gives us the per-VPS slice.

In v0, we use a single VPS with a single public IP (or a small static set). v0.5 PR 2 adds Hetzner IP allocation but the per-customer-IP-per-VPS pattern only matters at 10+ customers; before that, a single VPS with shared public IPs is fine.

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

### ADR-017: the Go service is the spine (NEW)

**Context:** v0's Go service is two small L4 forwarders. v0.5 grows it into provisioning, admin API, probes, and probe collection. v1's control plane is a separate service, but cococoir-edge and cococoir-client are the runtime interface to the cloud side. Without a clear scope statement, "the Go service grows" tends to accrete features until it's a 10k-line monster that does everything poorly.

**Decision:** The cococoir-edge and cococoir-client binaries are the **spine** of the cococoir cloud. The spine's scope is bounded by the following:

*In scope:*
- L4 data path (the forwarder; forever simple per ADR-006)
- Hetzner Cloud API client (IP allocation, server inventory)
- Hetzner DNS API client (record management)
- Customer record CRUD (in bbolt in v0.5, Postgres in v1)
- Admin HTTP API (operators, via bearer token over WireGuard)
- Probe execution (cococoir-client)
- Probe result collection (cococoir-edge)
- Local operational status (liveness, last-probe, error counters) exposed via admin API
- Hot-reload of the customer record store (in-memory + bbolt; no config-file-watching)

*Out of scope:*
- TLS termination (ADR-006, ADR-007)
- L7 routing (ADR-006)
- Web UI (deferred to v1)
- Stripe / billing (deferred to v1)
- Self-serve customer signup (deferred to v1+)
- WebSocket-based real-time control (deferred to v1+ if needed)
- Cluster-aware coordination (the spine is cluster-ready but doesn't coordinate; ADR-016)
- Multi-region / anycast (deferred to v2+)

**Consequence:** Every new feature proposed for cococoir-edge or cococoir-client gets checked against this list. "In scope" → design and ship. "Out of scope" → defer to the listed version. Anything not in either list → explicit ADR before adding.

The spine is monolithic within a single VPS in v0.5. The control plane (v1) is a separate service that orchestrates the spine; the spine doesn't know about the control plane's existence except via the admin API (which the control plane calls).

**Revisit when:** v1 ships and the spine's responsibilities need to be re-bounded for v2.

### ADR-018: config generation via Nix (`environment.etc` + `builtins.toJSON`, or `sops.templates` for secrets)

**Context:** The cococoir-edge and cococoir-client binaries read JSON configs. Where do the JSON files come from? Originally the test had hand-written JSON fixtures. That doesn't scale: when the operator wants to add 5 forwards, they don't want to write JSON by hand, and they want type checking.

**Decision:** Cococoir JSON configs are generated from Nix attrs at activation time, via one of two patterns:

- `environment.etc."cococoir-{edge,client}.json".text = builtins.toJSON { ... };` — for non-secret configs. The NixOS module places the file at `/etc/cococoir-{edge,client}.json`, which is the default `configFile` path. Operators compose forwards from a Nix attrset, Nix type-checks field names, the resulting JSON is reproducible.

- `sops-nix`'s `sops.templates."cococoir-{edge,client}.json".content = builtins.toJSON { ... };` — for configs that need secrets (e.g., Hetzner API token in v0.5 PR 2). The token path is interpolated from `config.sops.secrets.<name>.path`; the actual secret is read by the binary from that path at runtime.

The module's `configFile` option defaults to `/etc/cococoir-{edge,client}.json` so most operators don't need to override it. Operators who already have a JSON file in their dotfiles can point `configFile` at it.

**Consequence:** No separate `.json` fixture files in the test or in production. Type-checked configs. Easy secret interpolation. One source of truth (Nix).
**Revisit when:** A config file's content is too complex to be a Nix attrset (e.g., it has dynamic content that Nix can't express). None anticipated.

### ADR-019: bbolt for per-VPS customer record storage (NEW)

**Context:** v0.5 PR 2 needs a place to store customer records on the edge. Options: JSON files (simple, but racy under concurrent access from the admin API and the prober), SQLite (relational, but heavier), BoltDB / bbolt (key-value, single file, embeddable, no schema), Badger (key-value, more features, but more complex). The user (Nicole) specified "key value store" with bbolt or badger as candidates.

**Decision:** bbolt. BoltDB (the original) is unmaintained; bbolt is the etcd-io fork and the maintained successor. bbolt is one file, B+ tree, single-writer, simple API. It handles the "thousands of small reads, hundreds of small writes per minute" pattern that v0.5 needs (operator actions, probe result ingestion). Reversibility is good: the bbolt CLI can dump to text, or we write a small export tool in v1 when we migrate to Postgres.

Badger was the other candidate. Badger's LSM tree + MVCC is overkill for our scale and harder to dump by hand. The complexity isn't worth the throughput difference at <50 customers per VPS.

**Consequence:** One `/var/lib/cococoir/edge.db` file per VPS. Backup is a copy of the file (plus the Nix config). Migration to Postgres in v1 is a one-time export.
**Revisit when:** bbolt's single-writer becomes a bottleneck (unlikely for 50 customers on a single VPS).

---

## Design principles

These are the working principles for the v2 codebase. They generalize ADRs 011, 012, 018, and 019 and apply to every option we ever consider adding.

- **Wine-mom config.** A non-technical customer with a 5-minute debrief can fill out the customer config. Every option is a test surface, a doc burden, and a way to misconfigure. Optimize for the 99% case.
- **Cococoir picks.** Cococoir owns the namespace. Subdomains, bucket names, ports, paths, OIDC client names — all cococoir's choice. The customer fills in 3 fields.
- **Options on request.** Don't expose a knob until a real, repeated customer pattern demands it. Default to the most useful behavior. Revisit only with data.
- **Tests are leverage.** The test framework (L1 option tree, L2 VM boot, L2 2-VM edge↔client, L3 customer journey) is the highest-leverage artifact in this project. Every module change ships with a test. A test failure is a bug, not a flake.
- **The Go service is the spine.** cococoir-edge and cococoir-client grow to be the runtime interface to the cococoir cloud. Their scope is bounded by ADR-017.
- **Config-as-Nix, secrets-via-sops.** All cococoir configs are generated from Nix attrs. Secrets are interpolated via sops-nix's `sops.templates` (or `environment.etc` for non-secret configs).
- **Reversibility is asymmetric.** Monolith → split is easy; split → monolith is hard. We pick the structure that's easiest to refactor away from, not the one that's easiest to ship first.
- **No Big Tech telemetry.** No Sentry, no Datadog, no SaaS that sees customer data. The probe system writes to bbolt; operators query via the admin API. If we ever need a real observability stack, it's self-hosted (LGTM or similar) on cococoir infrastructure.

---

## Decisions still pending

Open questions for the next phases. Flagged so they don't get forgotten; not blockers for v0.5.

### Pending: control plane feature scope

What does the v1 control plane include? Must-haves:
- Customer onboarding (web form or API)
- IPv4 provisioning (Hetzner API) — cococoir-edge already does this in v0.5; the control plane orchestrates it
- DNS provisioning (Hetzner DNS API) — same
- Subscription status (manual or Stripe)
- Bandwidth tracking (cococoir-edge reports periodically)
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

How does the Go service report per-customer bandwidth to the control plane?
- Option A: per-customer counter in the Go service, exposed via the admin API
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

### Pending: customer-side WireGuard credential bootstrap (CGNAT story)

The customer box needs to get the WireGuard public key onto the VPS, and the VPS needs to get the customer's public key back to the box. v0 uses hardcoded test keys. v0.5 still has the operator wire WireGuard on both sides via Nix config. v1 is the natural place to automate this (control plane generates a one-time-use key, customer scans a QR code or visits a URL, public key flows back via HTTPS).

**Decision criterion:** Defer to v1. The 10-20 customer scale is small enough to wire manually.

(Resolved in PLAN_2.md: ADR-006 rewritten to preserve spirit not letter; ADR-017 added for the spine; ADR-018 added for config generation; ADR-019 added for bbolt.)

---

## Customer migration path

The customer (the nonprofit, using v1 on amon-sul) and amon-sul itself stay on v1 until v0.5 has earned the migration. Earned means:

1. v0.5 ships (when the 4-PR backlog is done and verified).
2. v0.5 has run on a real box (not just VM tests) for at least 1 week with no critical issues.
3. The 2-VM nixosTest and the 3-VM nixosTest (from PR 4) continue to pass.
4. (Offsite backup is **not** a prerequisite — per the user's decision, it's deferred. Data-loss risk during cutover is documented and accepted.)

When v0.5 is ready:
1. amon-sul flake.nix: change `cococoir.url` from `?dir=v1` to root.
2. `nix flake update cococoir && nixos-rebuild switch`.
3. Verify: all services still up, customer can still log in, garage still has the data.
4. Customer notification: "We upgraded your box's underlying software. You might see a brief downtime during the switch. Nothing on your end changes."

If migration fails, the rollback is: change the URL back, `nix flake update`, `nixos-rebuild switch`. Five minutes. This is why the v1 → v2 split is in two directories instead of in-place refactoring.

---

## Risks and honest concerns

### Risk: v0.5 is the bottleneck

**Severity:** Medium. v0.5 is 4 PRs over 4 weeks for one person. The "production-grade" v0.5 (Hetzner client, admin API, probes, control channel, real auth) is closer to 6-8 weeks.
**Mitigation:** v0.5 PR 4 is the explicit kill criterion. If we don't reach "edge + Hetzner provisioning + admin API + 1 customer in a customer-journey VM test" in 4 weeks, fall back to v1 + new tests.

### Risk: Hetzner API client is a yak-shave

**Severity:** Medium. The Hetzner Cloud and DNS APIs are well-documented, but the Go client is a new dependency. API token handling, idempotency, retry-on-5xx — all of these have to be done right.
**Mitigation:** Mock the Hetzner client in tests (HTTP test server). Idempotency is the design constraint: every provision operation is safe to re-run.

### Risk: cert rate limits bite at scale

**Severity:** Low for v0.5, high at 1000 customers.
**Mitigation:** Spread cert issuance across the week. Plan for single-wildcard `*.untitledbusiness.info` in v1+ if needed.

### Risk: "hosted only" means we own the apex

**Severity:** Medium. If `untitledbusiness.info` has a DNS outage, every customer is down.
**Mitigation:** Use Hetzner DNS's SLA + consider a fallback DNS provider (secondary NS). Defer to v1+.

### Risk: operator workflow doesn't scale past 10-20 customers even with v0.5

**Severity:** Medium. v0.5 is git + admin API + manual rebuilds. At 10-20 customers, the operator (Nicole) hits the wall: "I can't add another customer tonight, I'm behind on X." This is the trigger to build v1.
**Mitigation:** v1 is on the shelf as soon as v0.5 ships.

### Risk: control plane is a large project

**Severity:** High. 1-3 months of one person's work. v0.5 ships before v1 exists; v1 is its own milestone. Don't try to build it before v0.5 ships.
**Mitigation:** Treat v1 as a separate project. Scope it tightly. Defer the optional features (Stripe, multi-machine self-serve) until the must-haves (customer records, IP provisioning, subscription) are working.

### Risk: bbolt's single-writer is a bottleneck

**Severity:** Low for v0.5. Single-writer bbolt can handle thousands of small writes per second. Probe result ingestion is the heaviest workload (~1 write per probe per customer per minute); at 50 customers × 1 probe/min, that's 0.83 writes/sec. Well under the limit.
**Mitigation:** If bbolt's writer becomes a bottleneck, batch probe results in memory and flush periodically. Or migrate to Badger (LSM tree, concurrent writer). Either is a v1+ problem.

### Risk: PostgreSQL single point of failure (until hot standby exists)

**Severity:** Low for v1. Single-instance Postgres is fine; loss of the DB is recoverable from backups.
**Mitigation:** Hot standby from v1 day 1. pg_dump + WAL archiving for offsite backups. Document the recovery procedure.

### Risk: the 4-week kill criterion

**Severity:** Medium-high. If v0.5 stalls, we need to apply the testing infra to v1 instead.
**Mitigation:** The test harness is built in v0.5 with the explicit goal of "can be applied to v1." The 2-VM and 3-VM nixosTests work against v1 modules with minimal changes.

### Risk: PocketID admin-creation flow is fragile

**Severity:** Medium. The PocketID API for user creation is thin on documentation. The PocketID item in the implementation backlog might stretch.
**Mitigation:** Fallback plan: `signupMode = "withToken"` and have a one-time signup token in sops. Less elegant, but works.

### Risk: customer can't wait

**Severity:** Low. The customer is the nonprofit, and Nicole has a relationship. They're tolerant. The 4-8 week v0.5 timeline is fine.
**Mitigation:** Keep the customer informed. "We're working on reliability improvements. You might see a brief switch-over in 4-8 weeks."

### Risk: Hetzner has an outage

**Severity:** Low. Hetzner has good uptime. Multi-region is a v1+ concern.
**Mitigation:** Document the runbook for "Hetzner is down, what do we do."

### Risk: the company name placeholder

**Severity:** Trivial. We use `untitledbusiness.info` as a placeholder until the cooperative picks a real name.
**Mitigation:** Make the placeholder easy to change. One config option.

### Risk: I (the AI agent) am not actually doing the work

**Severity:** Real. The plan assumes Nicole is writing code. I'm writing the plan and asking questions. The v0 2-VM test shipped because Nicole sat down and drove it through five or six rounds of `nix flake check` failures. The current next action (v0.5 PR 1: the forwarder refactor) is the next thing Nicole needs to drive.
**Mitigation:** Be honest about who does what. I help with design, code review, debugging, and writing the trickier bits. Nicole does the integration, the testing, the deployment. I don't pretend to be her.

---

## Current next action: ship v0.5 PR 1 (forwarder growth)

What v0.5 PR 1 produces, and what verifies it:

1. **Refactor to a single Go module.** `nix/packages/edge/` and `nix/packages/client/` become one module at `nix/packages/edge/`. The shared forwarder code lives in `nix/packages/edge/internal/forwarder/`. Two `cmd/` entry points: `nix/packages/edge/cmd/edge/main.go` and `nix/packages/edge/cmd/client/main.go`. Two Nix packages still: `nix/packages/edge/` (the forwarder module) and `nix/packages/edge/client.nix` (the client package that picks the right binary out of the buildGoModule output).
2. **Per-IP binding pattern.** A forward can specify which local interface to listen on. The forwarder resolves the interface's IP at startup. If the interface doesn't have the IP yet, the binary retries with exponential backoff.
3. **Better signal handling.** Graceful shutdown closes all listeners, waits for in-flight connections to drain (timeout: 30s).
4. **2-VM nixosTest updated.** The test now binds the edge to a specific local IP (e.g. `192.168.1.10`) instead of `0.0.0.0`, exercising the per-IP binding code path. The client stays at `10.10.0.2:80` (its WG IP).
5. **Unit tests for the listener registry.** `go test` in `internal/forwarder/` exercises: bind to specific IP, retry on transient failure, graceful shutdown.
6. **`nix flake check` passes.** L1 (tenant-options), L2 (tenant-vm), L2 (edge-forward), and a new unit-test check (the forwarder's go test).

**Why this PR before the others:** consolidation of duplicated code is the cheap prerequisite for everything else. PRs 2-4 all build on the forwarder; starting from a clean shared codebase is faster than building on duplication and refactoring mid-PR.

**Verification:** `nix flake check` passes. The 2-VM nixosTest runs the new per-IP binding path. `go test ./internal/forwarder/...` passes locally and in CI.

**After this:**
- v0.5 PR 2 (Hetzner client + bbolt) is the next item, in build order.
- v0.5 PRs 3-4 follow.
- Then: cut over the customer (the nonprofit) from v1 to v0.5.

---

## Related documents

- `/home/nicole/Documents/untitled-business/writing/plan.md` — the business plan. Why cococoir exists, who it's for, what the market looks like.
- `PLAN.md` — the v0 plan (this document's predecessor). Kept for reference. Superseded by this document for the long-term direction.
- `cococoir/v1/AGENTS.md` — the v1 architecture. Kept for reference; will not be updated.
- `cococoir/v1/PLAN-OLD.md` — the previous version of PLAN.md (the Phase 0/1/2/3 plan that was pivoted away from). Kept for reference.
- `/home/nicole/Documents/amon-sul/AGENTS.md` — the amon-sul deployment. Will need a v2 section once the customer migrates.

---

## Open questions for future ADRs

When these come up, write a new ADR and link it from here. Don't let the open-questions list grow without decisions.

- Storage topology: shared vs per-customer (still open; v0 = per-customer, defer decision).
- The "company name" decision (placeholder `untitledbusiness.info`).
- Multi-region (deferred to v2+; not a v0.5 blocker).
- Self-service customer onboarding (deferred to v2+; v0-v1 is operator-driven via git / admin API / control plane).
- Backup and DR policy (deferred past v0.5; user said skip for v0).
- Observability stack (deferred to v1; v0.5 is bbolt + admin API).
- Runbooks (deferred to v1).
- Release discipline (deferred to v1).
- Public status page (v1 / v2+).
- Cert strategy at scale (50+ customers).
- Customer-side WireGuard credential bootstrap (CGNAT story; deferred to v1).

Resolved (now in ADRs):
- Two binaries: implicit in v0 architecture + ADR-017 scope.
- L4 data path, control surface in scope: ADR-006 rewrite.
- Spine scope: ADR-017.
- Config generation pattern: ADR-018.
- bbolt for storage: ADR-019.
- IPv4 allocation strategy: ADR-014 (per-customer IPv4 required) + ADR-016 (per-VPS cluster).
- Drop clan-core: ADR-010 (v2 doesn't depend on clan-core).
- WireGuard mesh topology: ADR-016 (star with per-customer IP per VPS).
