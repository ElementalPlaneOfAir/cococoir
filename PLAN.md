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

- v1 cococoir (the current repo at `cococoir/`) is post-MVP: the 4-option service contract works, garage is running on amon-sul, OIDC Phase 1 (PocketID as base layer) just shipped. But there are gaps: no tests, no offsite backup, no observability, OIDC service wiring deferred, no multi-tenant model, the rathole-based tunnel is a real liability at scale.
- 1 customer is waiting (the nonprofit). Nicole hasn't felt comfortable deploying more customers until reliability improves.
- `amon-sul` is the personal test rig. The customer's data is on it. Reliability work on amon-sul directly benefits the customer.

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

### The 2-week goal (aspirational, not a deadline)

Nicole's stretch goal: ship a working v0 (first v2 release, minimum lovable) in 2 weeks. v0 is defined in the "v0 Architecture" section below. The 2-week number is motivation, not a hard deadline. Realistic v0 is 2-4 weeks. The honest milestones:

- **Week 2** (stretch): `nix flake check` passes the full customer-journey test.
- **Week 4** (realistic): v0 is feature-equivalent to v1's must-haves (PocketID + Garage + 1-2 services + OIDC for those services).
- **Week 6** (definite): v0 is feature-equivalent to v1. v1 freezes (bug fixes only). Customer migration begins.

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
- **Turn off** services they don't want (`cococoir.tenant.alice.services.qbittorrent.enable = false`)
- **Override** individual subdomains if they want non-standard naming

The customer **cannot**:
- Add their own services (cococoir decides what's available)
- Configure service internals (cococoir picks ports, buckets, settings)
- Bring their own domain in v0 (deferred to v1; v0 is hosted-only)

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

## v0 build plan: the 2-week sprint

This is the day-by-day build. Each day has a deliverable, a test, and a verification step. The plan is aspirational; real delivery is probably 2-4 weeks. If we're not at "garage + pocketid + 1 service + OIDC working in a VM" by end of week 4, we hit the kill criterion and pivot.

### Day 1-2: project skeleton + v1 move

**Goal:** Two parallel things. A clean v2 project, and v1 moved to a subdirectory so amon-sul keeps working.

- Create `cococoir/v2/` directory (or `cococoir-v2/` repo; decision below) with:
  - `flake.nix` — flake-parts, minimal inputs (nixpkgs + flake-parts + import-tree)
  - `nix/nixos-modules/default.nix` — aggregator
  - `nix/nixos-modules/cococoir.nix` — placeholder module that just defines `options.cococoir.tenant.<name>` as a freeform attrset (no logic yet)
  - `nix/tests/default.nix` — one placeholder test
  - `nix/lib/` — empty for now
  - `scripts/` — empty for now
  - `PLAN.md` — this document (move the old one to `cococoir/v1/PLAN-OLD.md` or delete it)
- Move existing cococoir content to `cococoir/v1/` via `git mv` (preserves history)
- Update `amon-sul/flake.nix`: change `cococoir.url = "github:ElementalPlaneOfAir/cococoir"` to `cococoir.url = "github:ElementalPlaneOfAir/cococoir?dir=v1"`. Verify `nix flake check` still works.
- `nix flake check` on the new v2: passes (one trivial test).

**Test:** `nix flake check` passes in both `cococoir/` (v2) and `amon-sul/` (v1).

**Verification:** I can spin up a VM from the v2 flake and it boots.

### Day 3-4: tenant module

**Goal:** `cococoir.tenant.<name>` is a real option tree. The 3 inputs work. Subdomain derivation works.

- `nix/nixos-modules/tenant.nix`:
  - `cococoir.tenant.<name>.domain` (str, required)
  - `cococoir.tenant.<name>.adminUser` (str, required)
  - `cococoir.tenant.<name>.adminPasswordFile` (path, required)
  - Derived: `cococoir.tenant.<name>.pocketidDomain = "auth.${domain}"`
  - Derived: `cococoir.tenant.<name>.services.<name>.domain = "${name}.${domain}"` for each known service
- `nix/lib/derive-subdomains.nix`: helper that, given a tenant config, produces all the derived options
- `nix/nixos-modules/services/<name>.nix`: placeholders for jellyfin and cryptpad (just option definitions, no real config yet)
- Test: `cococoir.tenant.alice.domain = "alice.untitledbusiness.info"` evaluates; all derived subdomains are correct.

**Test:** NixOS test that evaluates a tenant config and asserts each derived subdomain is correct.

**Verification:** `nix eval` shows the right values.

### Day 5-6: PocketID with admin-creation flow

**Goal:** PocketID runs in a VM, the admin user (from sops) is created at first boot, the customer can log in.

- `nix/nixos-modules/pocketid.nix`:
  - Wraps nixpkgs `services.pocket-id`
  - Sets `APP_URL`, `TRUST_PROXY = true`, `ALLOW_USER_SIGNUPS = "disabled"`
  - `environmentFile` for secrets
- `nix/nixos-modules/services/pocketid-secret-init.service`:
  - Generates `ENCRYPTION_KEY` + `STATIC_API_KEY` if missing
  - Idempotent
  - Mode 0640, owned by `pocket-id:pocket-id`
- `nix/nixos-modules/services/pocketid-admin-init.service` (NEW):
  - Waits for PocketID to be healthy (polls `APP_URL/api/health`)
  - Uses `STATIC_API_KEY` to call PocketID's API
  - Creates the real human admin user (username + password from sops)
  - Idempotent: if admin exists, do nothing
  - Optional: rotates / disables the static key after admin creation
- Test: VM with PocketID, run admin-init, verify the admin user exists in the DB, can log in via API.

**Test:** Full PocketID lifecycle in a VM.

**Verification:** `curl -X POST $APP_URL/api/auth/login` with admin creds returns a session.

### Day 7-8: Go edge service v0

**Goal:** Go service that forwards TCP + UDP from a VPS IP to a customer box over WireGuard. Tested with 2 VMs.

- `nix/packages/edge/`:
  - `main.go` — Go program: `socat`-style TCP/UDP forwarder, configured via a TOML or JSON file
  - `go.mod` — Go module
  - `default.nix` — `pkgs.buildGoModule`
- `nix/nixos-modules/edge.nix`:
  - `services.cococoir-edge` systemd service
  - Reads `/etc/cococoir/edge.toml`
  - Configures WireGuard interface via `networking.wireguard.interfaces.wg0` (kernel does crypto/auth)
  - Hot-reload on SIGHUP (re-reads config)
- Test: 2 VMs. One runs `services.cococoir-edge`. The other connects via WireGuard, sends a TCP packet to a known port, verifies the packet reaches a service on the edge side.

**Test:** End-to-end packet forwarding through the edge service.

**Verification:** `tcpdump` shows the packet on both sides of the tunnel.

### Day 9-10: Garage module

**Goal:** Port v1's garage to v2. Single-tenant cluster per customer.

- `nix/nixos-modules/garage.nix`: copy/adapt from `cococoir/v1/modules/storage/garage.nix`
- `nix/nixos-modules/garage-bucket-init.nix`: copy/adapt from `cococoir/v1/clan-services/garage/bucket-init.sh`
- Test: 1-VM garage, single-tenant cluster, write a file, read it back.

**Test:** Garage single-node smoke test.

**Verification:** `mc ls` (or `s3cmd`) reads the bucket.

### Day 11-12: Caddy module with ACME DNS-01

**Goal:** Caddy on the customer box serves HTTPS for `*.${domain}` with a real cert from Let's Encrypt (staging env for tests).

- `nix/nixos-modules/caddy.nix`:
  - Enables Caddy
  - Opens UDP 443 (HTTP/3)
  - Configures a vhost for `*.${domain}` that uses ACME DNS-01 with the Hetzner DNS module
  - DNS API token from sops
- Test: VM with Caddy, request `*.test.example`, get a cert from Let's Encrypt staging, serve HTTPS.

**Test:** Caddy + ACME DNS-01 in a VM.

**Verification:** `curl https://jellyfin.${domain}` returns a real cert (not self-signed).

### Day 13-14: first end-to-end customer-journey test

**Goal:** `nix flake check` runs a test that exercises the full customer journey in a VM. The 3 inputs are enough.

- One VM with all 4 components: tenant config, PocketID, Garage, Caddy
- VM is configured with `cococoir.tenant.testcustomer.{domain, adminUser, adminPasswordFile}`
- Test script:
  1. Boot VM
  2. Wait for PocketID to be healthy
  3. Run pocketid-admin-init
  4. Log in to PocketID with the admin creds
  5. Verify a session is returned
  6. Make a request to `jellyfin.${domain}` over HTTPS
  7. Verify Jellyfin is reachable and accepts the (eventual) OIDC token
- `nix flake check` runs this and asserts pass.

**Test:** Full customer journey in a single VM.

**Verification:** `nix flake check` is the single source of truth.

### Post-2-weeks (if we got here)

- Migrate amon-sul to v2 (change flake input from `?dir=v1` to root)
- Cut over the customer (the nonprofit)
- v1 freezes
- v1 → v2 service migration: jellyseerr, qbittorrent, autobrr, matrix, mautrix-gmessages, nextcloud, custom
- Phase 2 begins: multi-tenant on a VPS pool

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

---

## Decisions still pending

These are the open questions for the next phases. They are flagged here so they don't get forgotten, but they are *not* blockers for v0.

### Pending: IPv4 allocation strategy (Phase 2)

How do we get 1000 IPv4 addresses?

Options:
- Hetzner Cloud: each VM has 1 IPv4 + 1 IPv6 by default; additional IPv4 is €0.50/month each. A single VM with 10 IPv4 = €5/month.
- Hetzner Cloud /28 network: 13 IPv4 in a subnet, €0/month (free with /28).
- Multiple VPS instances, each with a /28 or /27.
- Alternative providers (BuyVM has cheap IPv4; OVH has /24 available; Vultr, DigitalOcean, etc.).

**Research needed:** Cost comparison, IP availability, geographic distribution, BGP considerations (if any).

### Pending: Storage topology at scale (Phase 2)

One big Garage cluster shared by all customers, or per-customer Garage clusters?

- Per-customer: simpler isolation, easier reasoning, but N× the operational cost.
- Shared with quotas: scales better, but per-customer isolation requires careful bucket policies.

**Research needed:** Garage's quota and policy features. Performance under many buckets.

### Pending: Customer name registry (Phase 2)

How do we track that `alice.untitledbusiness.info` is taken?

- v0: git-tracked file (`customers.txt` or a JSON file in the cococoir repo).
- v1: a proper tool with conflict detection, possibly a tiny web UI.
- v2: a database.

**Research needed:** What fits the sales workflow.

### Pending: Cert strategy at scale (Phase 1+)

When we have 50+ customers, Let's Encrypt rate limits become real. Options:

- Wildcard per customer: `*.alice.untitledbusiness.info` (one cert per customer, rate-limited at 50/week for the apex).
- Single wildcard for the apex: `*.untitledbusiness.info` (one cert, but compromised if any subdomain is compromised).
- SAN cert: one cert with multiple subdomains (LE has separate rate limits for SAN).

**Research needed:** What's the actual bottleneck at 100, 500, 1000 customers. What's the security model if we go single-wildcard.

### Pending: Drop clan-core? (Day 1-2 decision)

The user has questioned whether clan is the right tool. v0's Day 1-2 might be a good time to evaluate:

- Plain sops-nix + a deploy script (matches what `tunnel/` does today).
- Colmena (similar model to clan, smaller surface area).
- Stay with clan-core.

**Decision criterion:** After v0's testing harness is working, evaluate. Decide with data, not in the abstract.

### Pending: WireGuard mesh topology (Day 7-8)

- Star (each customer → 1 VPS): simplest, scales to N VPS with customer routing tables.
- Full mesh (customer ↔ customer): not needed for v0; defer.
- Per-customer VPS: each customer is on their own VPS. Limits scale, increases cost. Probably wrong for 1000 customers.

**Decision:** Star, for v0. Revisit when N > 50 per VPS.

---

## Customer migration path

The customer (the nonprofit, using v1 on amon-sul) and amon-sul itself stay on v1 until v2 has earned the migration. Earned means:

1. v0 ships (Day 13-14, or whenever).
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

**Recommendation:** Add a Day 14.5 task: "offsite backup to Hetzner Storage Box." This is 1-2 days of work. Backup before the customer migrates, not after.

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

### Risk: the 4-week kill criterion

**Severity:** Medium-high. If v2 stalls, we need to apply the testing infra to v1 instead.
**Mitigation:** The test harness is built in v2 with the explicit goal of "can be applied to v1." Day 1-2 has verification step: "the test harness works against v1 modules too."

### Risk: PocketID admin-creation flow is fragile

**Severity:** Medium. The PocketID API for user creation is thin on documentation. Day 5-6 might stretch.
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

**Severity:** Real. The plan assumes Nicole is writing code. I'm writing the plan and asking questions. The Day 1-2 work needs Nicole to actually sit down and start. The 2-week goal is for *her*, not for me.
**Mitigation:** Be honest about who does what. I help with design, code review, debugging, and writing the trickier bits. Nicole does the integration, the testing, the deployment. I don't pretend to be her.

---

## Day 1-2: the next action

The first 48 hours of v0. This is the next concrete work.

### Step 1: Create the v2 project skeleton

`cococoir/` (root) becomes v2. Create the following structure:

```
cococoir/
├── flake.nix                 # flake-parts, minimal inputs
├── nix/
│   ├── nixos-modules/
│   │   └── default.nix       # aggregator
│   ├── tests/
│   │   └── default.nix       # one placeholder test
│   └── lib/                  # empty for now
├── scripts/                  # empty for now
├── PLAN.md                   # this document
├── AGENTS.md                 # new, replacing v1's AGENTS.md
└── v1/                       # old code, moved via git mv
    └── ...                   # everything from the current cococoir/
```

### Step 2: Write `flake.nix` for v2

Minimal flake-parts flake. Inputs: nixpkgs, flake-parts, import-tree. Outputs: `nixosModules.default` (aggregates `nix/nixos-modules/`), `tests.<name>` (aggregates `nix/tests/`).

### Step 3: Write the placeholder test

A nixosTest that imports the empty cococoir module and asserts the system evaluates. No services enabled. Just proves the flake is wired correctly.

### Step 4: Move v1 to `cococoir/v1/`

```bash
cd cococoir
git mv modules v1/modules
git mv flake-vars v1/flake-vars
git mv clan-services v1/clan-services
git mv storage v1/storage
git mv tunnel v1/tunnel
git mv AGENTS.md v1/AGENTS.md
git mv PLAN.md v1/PLAN-OLD.md  # keep the old plan for reference
```

(Don't move `flake.nix` — that's getting rewritten.)

### Step 5: Update amon-sul

In `amon-sul/flake.nix`:
```nix
cococoir = {
-  url = "github:ElementalPlaneOfAir/cococoir";
+  url = "github:ElementalPlaneOfAir/cococoir?dir=v1";
   inputs.nixpkgs.follows = "nixpkgs";
};
```

### Step 6: Verify both build

```bash
# v2 skeleton works
cd cococoir
nix flake check

# v1 still works
cd /home/nicole/Documents/amon-sul
nix flake check
```

Both should pass. If either fails, debug before moving on.

### Verification

- `cococoir/nix flake check` passes (v2 skeleton works).
- `amon-sul/nix flake check` passes (v1 is still operational through the `?dir=v1` URL).
- The cococoir repo has the new structure (v2 at root, v1 in subdir, PLAN.md rewritten).

### After Day 1-2

Move to Day 3-4: tenant module. The plan in this document is the source of truth; update it as decisions change.

---

## Related documents

- `/home/nicole/Documents/untitled-business/writing/plan.md` — the business plan. Why cococoir exists, who it's for, what the market looks like.
- `cococoir/v1/AGENTS.md` — the v1 architecture. Kept for reference; will not be updated.
- `cococoir/v1/PLAN-OLD.md` — the previous version of this document. The Phase 0/1/2/3 plan that the user pivoted away from. Kept for reference.
- `/home/nicole/Documents/amon-sul/AGENTS.md` — the amon-sul deployment. Will need a v2 section once the customer migrates.

---

## Open questions for future ADRs

When these come up, write a new ADR and link it from here. Don't let the open-questions list grow without decisions.

- IPv4 allocation strategy at 1000 customers.
- Storage topology: shared vs per-customer.
- Customer name registry implementation.
- Cert strategy at scale.
- Drop clan-core or keep it.
- WireGuard mesh topology beyond star.
- The "company name" decision.
- Multi-region (v2+).
- Self-service customer onboarding (v2+).
- Backup and DR policy (v0.5).
- Observability stack (v0.5).
- Runbooks (v0.5).
- Release discipline (v0.5).
- Public status page (v0.5).
