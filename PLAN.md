# Cococoir Plan

The home server product, end to end. Source of truth for what we're
building, in what order, against what gate. Older plans live in
`archive/`.

## Product

A home server in a box. NixOS + Garage (S3) + a small catalog of
services (Jellyfin, Nextcloud, Cryptpad, qBittorrent, …) + WireGuard
remote access (later) + sops-nix for secrets. See `BUISNESS-PLAN.md`
for the customer-facing rationale and the unit economics.

The product target is the residential customer. The technical debt
problem we're solving: traditional homelab setups fail non-technical
users. Cococoir succeeds by shipping a single NixOS config the
customer can install and forget about, with reliability and
observability built in.

## Versions

The product evolves in generations. Each version is a *generation*
of the system, not a release phase. The version numbers track
customer-facing scope, not internal implementation order.

| Version | What it is | Status | Gate |
|---------|-----------|--------|------|
| **v0** | L4 forwarder (`cococoir-edge` + `cococoir-client` Go binaries, NixOS modules, health endpoint, bbolt store) | Shipped | 2-VM nixosTest (`nix/tests/edge/`) |
| **v1** | Legacy home server (clan-core, Garage, FUSE mounts, services, rathole tunnel) at `v1/` | Frozen — soft deprecated. Features port to v2; no new development. | (n/a) |
| **v2** | New home server (flake-parts + sops-nix, uses the v0 forwarder, S3 storage, local OTEL observability, embedded dashboard) | Target | 1-VM nixosTest (Jellyfin + Nextcloud + Garage + cococoir-client + sops) |
| **v3** | Control plane (Postgres + auto-provisioning + web UI, multi-tenant) | Deferred. Trigger: 10-20 customers. | (n/a yet) |
| **v4** | Cluster expansion (multiple VPSes, each holding a slice of customers) | Deferred. Trigger: 50-100 customers or geographic need. | (n/a yet) |

**Why v0 ships before v2 is "done":** the v0 L4 forwarder is the
foundation v2 builds on. Shipping it first lets the WireGuard /
remote-access path (the harder of v2's two halves) be tested
independently of the storage / services path. The 2-VM nixosTest
proves the L4 path works. The 1-VM nixosTest for v2 proves the
storage path works. Composing them is the v2 product.

**Why v1 is frozen, not deleted:** it has battle-tested features
(Garage oneshot logic, FUSE-mount systemd wiring, per-service
modules) that we're porting to v2 one piece at a time. The `v1/`
directory stays as a reference. No new development; features get
ported, not edited in place. v1's flake and clan wiring do not
need to keep working — we only read it as a source of patterns.

## v0 — L4 forwarder (shipped)

Two Go binaries at `nix/packages/cococoir/`:

- **`cococoir-edge`** — VPS-side L4 forwarder. Per-IP binding, retry
  with backoff on transient bind errors, graceful shutdown.
- **`cococoir-client`** — customer-box-side L4 forwarder. Receives
  WireGuard traffic, forwards to `127.0.0.1:<port>` where local
  Caddy terminates TLS. The binary also embeds a prober, a
  journald tailer, an OTEL SDK, and an embedded dashboard
  (those land in v2 work; v0 ships the forwarder + health endpoint).

Shared packages in `nix/packages/cococoir/internal/`:

- **`forwarder`** — TCP + UDP forwarding, retry, drain, signal
  handling. ~15 unit tests.
- **`health`** — `/healthz` (always 200), `/readyz` (200 if any
  forward is bound), `/status` (JSON snapshot of forwarder state
  with `Component`, `Forwards`, `TCPConns`, `UDPFlows`). ~9 tests.
- **`logger`** — structured slog with `text` and `json` formats.
  ~4 tests.
- **`store`** — bbolt-backed customer record store. ~13 tests.

The 2-VM nixosTest at `nix/tests/edge/default.nix` exercises the
full data path (`curl → cococoir-edge :80 → WG → cococoir-client :80
→ python :80`) plus the health endpoint. **Gate: green.**

What v0 does *not* do (intentionally):

- TLS termination. Caddy on the customer box owns it.
- Application-layer inspection. The forwarder is L4.
- Auto-provisioning of IPs. Operator does this in Nix today.
- A web UI. Health endpoint is HTTP/JSON; humans use `curl`.

## v2 — Home server (target)

The full cococoir product for a single-machine deployment. The
customer (or operator) installs NixOS, applies the cococoir flake,
and gets a working home server with S3-backed storage and local
OTEL observability.

### Goals

- **Single-machine deployment.** No remote access in v2 — that's
  v3. The forwarder is in the binary but does nothing until a
  WireGuard peer is configured (later).
- **S3 storage via Garage (1-node).** Each service has its own
  bucket where appropriate (`media` for Jellyfin, `documents` for
  Nextcloud, etc.). Per-bucket replication factor. Native S3 where
  the service supports it (Nextcloud), FUSE mount otherwise
  (Jellyfin, qBittorrent).
- **Local OTEL observability.** Prober (HTTP GETs) emits OTEL
  traces; journald tailer emits OTEL logs. In-memory OTEL SDK
  exporter. Embedded dashboard at `:9090` showing services +
  recent probes + recent logs.
- **sops-nix for secrets.** Age-encrypted secrets in the user's
  repo. `nix run .#init` and `nix run .#add-secret` helpers for
  the first-time setup.
- **No multi-tenant, no remote access, no edge.** That's v3.

### Components

#### Storage (NixOS module at `nix/nixos-modules/storage/garage.nix`)

The `cococoir.storage.*` option tree. The customer sets 5 secret
file paths; everything else is hardcoded (single-node v2). Services
auto-declare buckets and FUSE mounts when enabled.

- `cococoir.storage.enable` — always-on (default `true`)
- `cococoir.storage.secrets.{rpcSecretFile, adminTokenFile, metricsTokenFile, accessKeyIdFile, secretAccessKeyFile}` — file paths, populated by sops-nix
- `cococoir.storage.buckets.<name>.{replicationFactor}` — per-bucket, added by service modules
- `cococoir.storage.mounts.<name>.{bucket, mountPoint, readOnly}` — FUSE mount via `geesefs`, added by service modules

Single-node ports (3900/3901/3903), region, and layout are
hardcoded. Multi-node options will be added when v4 lands.

#### Services (NixOS modules at `nix/nixos-modules/services/`)

The four-option contract:

```nix
cococoir.services.<name> = {
  enable    = true;                       # opt-in toggle
  domain    = "<service>.<base-domain>";  # Caddy vhost
  public    = true;                       # Caddy reverse-proxies (false → 403)
  bucket    = "<bucket-name>";            # S3-backed data dir (omit if no bucket)
};
```

Hidden options, not in the contract, filled in by the service
module: `cococoir.services.<name>.journald.units` (systemd units
to tail for the journald OTEL log stream),
`cococoir.services.<name>.healthUrl` (URL the prober GETs for
liveness), `cococoir.services.<name>.port` (local bind).

Initial services: **Jellyfin** (FUSE mount, RF=1 `media` bucket)
and **Nextcloud** (native S3, RF=3 `documents` bucket). Add
PocketID + OIDC wiring as the third service.

The prober and journald tailer read these options from the
cococoir config (Nix → JSON) and the prober knows what URL to
GET per service.

#### cococoir-client extensions (Go)

The `cococoir-client` binary (v0) gets three new internal
packages:

- **`internal/probe`** — HTTP GET prober, periodic (default 60s),
  one OTEL span per probe: `{name: "probe <url>", kind: CLIENT,
  attributes: {http.url, http.status_code, http.method}, status:
  OK/ERROR, duration: <measured>}`. Reads `services` list from the
  cococoir config.
- **`internal/journald`** — tails `systemd` journal for each
  service's declared units. Emits one OTEL log record per entry:
  `{time, observed_time, severity_number, severity_text, body,
  attributes: {pid, exe, unit}}`. Reads `services.<name>.journald.units`
  from config.
- **`internal/otel`** — wires the OTEL SDK. `tracerProvider` and
  `loggerProvider` configured with a custom in-memory exporter
  (capped slices for the dashboard). OTLP exporter configured but
  pointed at a non-existent endpoint for v2 (edge export is v3).

The existing `internal/health` server grows three new endpoints:
`/` (HTML dashboard), `/api/probes` (recent probe results as JSON),
`/api/logs` (recent log records as JSON). The existing
`/healthz`, `/readyz`, `/status` endpoints stay.

The forwarder (`internal/forwarder`) does not change for v2. It
already supports an empty `forwards = []` config (no-op), which is
the v2 single-machine default.

#### Embedded dashboard (HTML/JS, embedded in the binary)

Three sections, vanilla HTML + JS, no framework:

1. **Services list** — name, status (up/down from most recent
   probe), last probe time, latency. Auto-refresh every 5s.
2. **Recent probes** — last 20 OTEL spans from the prober.
   URL, status code, duration, success/failure.
3. **Recent logs** — last 50 OTEL log records from the journald
   tailer, filtered by service unit. Time, severity, message.

HTML and JS are embedded in the Go binary via `embed.FS`. The
binary serves the dashboard at `:9090/` and the JSON endpoints at
`:9090/api/{probes,logs}`. No external dependencies. No build step.

#### sops-nix helpers (Nix flake apps)

Two `nix run` commands at the flake root:

- `nix run .#init` — generates an age keypair if missing, creates
  an encrypted `secrets.yaml` template with placeholders for the
  Garage RPC secret, admin token, metrics token, S3 access key id,
  and S3 secret access key, prints the public key for committing
  to `.sops.yaml`, and tells the user to commit and rebuild.
- `nix run .#add-secret <name>` — prompts for a single secret
  value, encrypts it, and adds it to the encrypted file.

Both run the standard `sops` CLI with the user's age key. The
flake provides the right command-line flags for the encrypted
file's path and key.

#### 1-VM nixosTest (the v2 gate)

`nix/tests/storage/default.nix`. Single NixOS VM. Asserts:

1. **Storage**: Garage is up (admin API on `:3903` responds), the
   `media` bucket exists (`garage bucket info media` succeeds), the
   FUSE mount at `/media/entertain` is writable (touch + read
   round-trip), the S3 access key works (PUT/GET a small object
   via `mc` or the AWS CLI).
2. **Secrets**: a sops-nix encrypted secret is decrypted at
   activation, the file lands at the right path with the right
   permissions.
3. **Reproducibility**: rebuild twice, same bucket list, same
   permissions, same FUSE mounts.

The test is hermetic: it generates its own age keypair, encrypts
test secrets, embeds them in the VM. No external network calls.

When the v2 product grows (cococoir-client extensions, service
modules, dashboard), the test grows alongside it. The 1-VM test
is the **v2 gate** — the thing that has to pass for v2 to ship.

### Architecture rules

These are the rules v2 enforces. They are non-negotiable.

- **L4 forwarder has no service knowledge.** The forwarder reads
  `forwards = [...]` from config; it does not know about Garage,
  S3, or any service. If you find yourself adding service logic to
  the forwarder, write a test for the prober/journald/dashboard
  instead.
- **Prober does HTTP GET, nothing else.** No POST, no PUT, no
  tracing. Spans come from OTEL SDK instrumentation of the HTTP
  client. A "smart" prober (one that POSTs to /status endpoints
  to verify deeper health) is a v2.5+ concern.
- **Journald tailer emits logs, not traces.** Logs are the right
  shape for "I have a stream of timestamped events per service."
  Traces are the right shape for "I tried to do this thing."
  Mixing them is wrong.
- **OTEL SDK is in-process, in-memory.** No external OTLP for v2.
  The in-memory exporter is the source of truth for the
  dashboard. Edge export is v3.
- **No PII sanitization yet.** Stripping user IDs and auth
  headers from OTEL batches is a v2.3 concern, after the local
  system is working end-to-end.
- **sops-nix only.** No clan-core. No age-key-in-git. The
  encrypted file is the source of truth; the age key lives
  outside the repo.
- **4-option service contract is sacred.** Adding a 5th option
  is a deliberate decision, not an accident. v2 ships with 4.
- **Native S3 > FUSE.** For services with a native S3 backend
  (Nextcloud, Backblaze B2, etc.), use it. FUSE-mounting a bucket
  as a service's data dir is the fallback for services without
  native S3 support (Jellyfin, qBittorrent, Cryptpad).

## v3 — Control plane (deferred)

The piece that replaces "operator edits git" with a real backend.
Go service + Postgres + HTTP API + web UI. Reads v2's bbolt files
as seed data. Triggered when the operator workflow gets painful at
10-20 customers.

- Customer records, subscriptions, usage, infrastructure state
- Auto-provisions IPv4 on the VPS via Hetzner API
- Auto-provisions DNS via Hetzner DNS API
- Tracks per-customer bandwidth (cococoir-edge reports periodically)
- Web UI for customers + operators
- Optional: Stripe integration, self-serve backup, self-serve
  multi-machine customers

Source of truth is Postgres. Nix is the deployment mechanism (a
Nix-config-generator reads from Postgres and emits attrsets;
NixOS rebuilds on each machine).

## v4 — Cluster expansion (deferred)

Multiple VPSes, each holding a slice of customers. Triggered at
50-100 customers or when geographic distribution becomes a hard
requirement.

- `cococoir.edge.hosts.<name>` option tree for VPS records
- `cococoir.tenant.<name>.edgeHost` for the assignment
- Per-VPS NixOS configurations, each filtering the tenant list by
  edgeHost
- Failover: WireGuard endpoint roaming + manual runbook
- Auto-failover: deferred (heartbeat + automatic tenant migration)

## ADRs

The decisions that shape v0–v2. Each is final unless explicitly
revisited.

- **ADR-001: Version naming.** v0 = L4 forwarder, v1 = legacy
  home server (frozen), v2 = new home server (target), v3 = control
  plane, v4 = cluster expansion. Numbers track generations, not
  release phases.
- **ADR-002: v1/ is legacy.** Frozen. Features port to v2 one
  piece at a time. v1's flake and clan wiring do not need to keep
  working. The directory stays as a reference.
- **ADR-003: sops-nix replaces clan-core in v2.** Clan is built
  for multi-machine cluster management with shared secrets. v2 is
  a single-machine deployment in a single user's repo. Sops-nix
  is direct: encrypted secrets in the repo, decrypted at
  activation. Simpler dependency, simpler mental model.
- **ADR-004: 4-option service contract.** Every service module
  exposes exactly `enable / domain / public / bucket`. Adding a
  5th option (`otel`, `healthUrl`, `port`, …) is a deliberate
  decision, not an accident. The contract keeps the config
  surface minimal for the non-technical customer.
- **ADR-005: Native S3 > FUSE.** Services with a native S3
  backend (Nextcloud) use it. FUSE-mounting a bucket as a service
  data dir is the fallback for services without native S3 support.
- **ADR-006: TLS keys never leave the box.** Caddy on the customer
  box owns TLS. The forwarder is L4 and never decrypts. The
  customer's x25519 keys only exist on their local device.
- **ADR-007: L4 forwarder has no service knowledge.** The
  forwarder reads `forwards = [...]` from config. It does not
  know about Garage, S3, or any service. Service logic lives in
  the prober/journald/dashboard extensions of `cococoir-client`.
- **ADR-008: Prober / journald / dashboard live in cococoir-client.**
  One binary, three internal packages. They share the JSON
  config, the slog logger, the OTEL SDK, and the health server.
  They do not share code paths.
- **ADR-009: Per-customer isolation via `cococoir.tenant` (v3+).**
  v0 has a tenant module for v0's B2B use case. v2 reuses the
  pattern when multi-tenant lands in v3.
- **ADR-010: Secrets stay in the user's repo.** Encrypted with
  sops-nix. The age key lives outside the repo (operator's
  laptop, customer's USB stick, or a SOPS-managed secret store).
- **ADR-011: Cococoir is a deployment tool, not a library.**
  Per the v1 audit (`v1/THE_GREAT_SIMPLIFICATION.md`). v2 carries
  this forward: the flake input shape stays, but we don't ship
  a separate "API contract" for imaginary future consumers.
- **ADR-012: Every customer gets every known service.** v0–v2 do
  not implement per-tenant service enable/disable. The 4-option
  contract is the *user's* choice of which services to enable;
  multi-tenant access control is a v3 concern.
- **ADR-013: Nix-as-source-of-truth.** Every machine's
  configuration is a Nix attribute set, evaluated and applied
  via `nixos-rebuild`. The operator never edits files on a live
  machine; the flake is the only source of truth.
- **ADR-014: L4 forwarder is stateless.** Given a config, it
  just runs. No runtime state to coordinate. Cluster expansion
  (v4) relies on this.
- **ADR-015: WireGuard handles transport authentication.**
  The kernel does crypto and peer authentication. cococoir-edge
  and cococoir-client configure the WireGuard interface; the
  kernel enforces that only valid peers can send packets. v2's
  single-machine deployment skips WireGuard (no remote access);
  v3 reintroduces it.
- **ADR-016: Per-customer IPv4 is the routing primitive.** Cococoir's
  network design requires (a) web traffic accessible over IPv4,
  (b) per-customer routing on a shared proxy, (c) TLS keys on
  the device. The only configuration that satisfies all three is
  per-customer IPv4. v3 implements the Hetzner API client; v2
  is single-machine and skips this.
- **ADR-017: Go service is the spine of v2.** Bounded scope: L4
  forwarder + prober + journald tailer + OTEL SDK + embedded
  dashboard. No control plane in Go (that's v3's separate
  service). No service logic in Go (services are NixOS modules).
- **ADR-018: Config generation via `environment.etc` + `builtins.toJSON`.**
  Module `configFile` defaults to `/etc/cococoir-{edge,client}.json`.
  Operators can override with a custom path.
- **ADR-019: bbolt for per-VPS storage at `/var/lib/cococoir/edge.db`.**
  v0 ships bbolt. v2's bbolt usage is the same (no schema change
  in this slice). Badger was rejected as more complex with no
  benefit at this scale.

## Implementation backlog

Build order. No dates. Each item: what it produces, what test
verifies it. "Done" = shipped, tested, committed.

### v0 — L4 forwarder (done)

- Forwarder: TCP+UDP, retry, drain, signal handling. **Tests:**
  `internal/forwarder` Go unit tests (8), 2-VM nixosTest data-path.
- Health endpoint: `/healthz`, `/readyz`, `/status`. **Tests:**
  `internal/health` Go unit tests (9), 2-VM nixosTest health
  assertions.
- Structured logging: slog, text/json formats, per-component
  attribute. **Tests:** `internal/logger` Go unit tests (4).
- bbolt store: `internal/store` with `Get`, `Put`, `Delete`,
  `List`, `Customer` typed layer. **Tests:** `internal/store` Go
  unit tests (13).

### v2 — Home server (in progress)

- **v2.1: Storage option tree + Garage wiring.** Port v1's
  `cococoir/storage` and `cococoir/garage` to v2 with sops-nix in
  place of clan-core. Single-node only (multi-node is v4). ~1 day.
  **Tests:** 1-VM nixosTest for storage at `nix/tests/storage/`.
  This is the v2 gate.
- **v2.2: Jellyfin service module.** Port v1's
  `services/jellyfin.nix` to v2's 4-option contract. FUSE-mounted
  data dir at `/media/entertain`. Caddy vhost, hardcoded port
  8096, hidden options for `journald.units` and `healthUrl`.
  ~half a day.
- **v2.3: Nextcloud service module.** Port v1's
  `services/nextcloud.nix` to v2. Native S3 backend
  (`objectstore.s3`) pointed at the `documents` bucket. Caddy
  vhost, hardcoded port, hidden options. ~half a day.
- **v2.4: cococoir-client `internal/probe`.** HTTP GET prober
  that reads the services list from config and emits one OTEL
  span per probe. ~1 day. **Tests:** Go unit tests with a fake
  HTTP server and an in-memory OTEL exporter.
- **v2.5: cococoir-client `internal/journald`.** sd-journal
  tailer that reads `services.<name>.journald.units` from config
  and emits one OTEL log record per entry. ~1 day. **Tests:** Go
  unit tests with a fake journal source.
- **v2.6: cococoir-client `internal/otel`.** Wires the SDK:
  tracer provider, logger provider, in-memory exporter, OTLP
  exporter (no-op for v2). Reads OTEL config from cococoir
  config. ~half a day.
- **v2.7: Embedded dashboard.** `embed.FS` with HTML/JS, three
  sections, auto-refresh. Extends `internal/health` with `/`,
  `/api/probes`, `/api/logs`. ~1 day.
- **v2.8: sops-nix helpers.** `nix run .#init` and
  `nix run .#add-secret`. ~half a day.
- **v2.9: 1-VM nixosTest for the v2 product.** Combines all of
  the above. Asserts storage works, services respond, OTEL data
  is emitted, secrets decrypt, dashboard renders. **Gate.**

### v2.x — follow-on (deferred until v2.9 is green)

- **v2.10: PocketID + OIDC.** Add PocketID as the third service,
  wire Nextcloud to it, assert the OIDC flow works. Second 1-VM
  test or extension of v2.9.
- **v2.11: Edge export.** Configure the OTLP exporter on
  cococoir-client to point at cococoir-edge. Add a 2-VM test
  (or extend the v0 2-VM test) that asserts OTEL data flows
  from client to edge.
- **v2.12: PII sanitization.** Strip user IDs and auth headers
  from OTEL batches before export. Configurable denylist.
- **v2.13: qBittorrent + autobrr + Jellyseerr.** Add the rest
  of the *arr stack. RF=1 `media` bucket shared with Jellyfin.
- **v2.14: Cryptpad.** FUSE-mounted data dir at
  `/var/lib/cococoir/cryptpad`. RF=1 `documents` bucket shared
  with Nextcloud (or separate `cryptpad` bucket, TBD).
- **v2.15: External OTEL backend.** Decide between embedded
  dashboard, Grafana, or both. v2.x is the place for this
  decision.

### v3 — Control plane (deferred)

- `internal/admin/` HTTP server with `POST /customers`,
  `DELETE /customers/{name}`, `GET /customers`,
  `GET /customers/{name}/status`. Auth via sops-nix bearer
  token, listener bound to the WireGuard interface.
- Hetzner Cloud API client (IP allocate/release).
- Hetzner DNS API client (record add/remove).
- Postgres + Nix-config-generator (reads DB, emits attrsets).
- Web UI for customers + operators.

### v4 — Cluster expansion (deferred)

- `cococoir.edge.hosts.<name>` option tree.
- Per-VPS NixOS configurations filtering tenant list by edgeHost.
- WireGuard endpoint roaming runbook.
- (Future) auto-failover via heartbeat + tenant migration.

## References

- `BUISNESS-PLAN.md` — customer-facing product rationale.
- `archive/PLAN.md` — v0 plan, kept for historical reference.
- `archive/PLAN_2.md` — v0.5 / v0 forwarder + control plane
  plan, kept for historical reference.
- `v1/` — legacy home server codebase (frozen).
- `v1/THE_GREAT_SIMPLIFICATION.md` — the v1 audit that informs
  v2's "deployment tool, not a library" stance.
- `v1/AGENTS.md` — v1 module conventions (4-option contract,
  clan patterns). Read for context when porting features.
