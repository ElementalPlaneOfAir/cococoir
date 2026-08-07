# Cococoir Plan

The home server product, end to end. Source of truth for what we're
building, in what order, against what gate. Older plans live in
`archive/`.

## Product

A home server in a box. NixOS + a small catalog of services
(Jellyfin, Nextcloud, Cryptpad, qBittorrent, …) + WireGuard remote
access (later) + btrfs storage + sops-nix for secrets. See
`BUISNESS-PLAN.md` for the customer-facing rationale and the unit
economics.

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
| **v0** | L4 forwarder (`cococoir-edge` + `cococoir-client` Rust binaries, NixOS modules, health endpoint) | Shipped | 2-VM nixosTest (`nix/tests/edge/`) |
| **v1** | Legacy home server (clan-core, Garage, FUSE mounts, services, rathole tunnel) at `v1/` | Frozen — soft deprecated. Features port to v2; no new development. | (n/a) |
| **v2** | New home server (flake-parts + sops-nix, uses the v0 forwarder, btrfs storage, 7 services with Dex OIDC) | Target | `scripts/vmtest-e2e.sh` PASS (Jellyfin + dex + cryptpad + btrfs + sops) |
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

One Rust crate at `nix/packages/cococoir/` producing two binaries:

- **`cococoir-edge`** — VPS-side L4 forwarder. Per-IP binding, retry
  with backoff on transient bind errors, graceful shutdown.
- **`cococoir-client`** — customer-box-side L4 forwarder. Receives
  WireGuard traffic, forwards to `127.0.0.1:<port>` where local
  Caddy terminates TLS. The binary also embeds a prober, a
  journald tailer, an OTEL SDK, and an embedded dashboard
  (those land in v2 work; v0 ships the forwarder + health endpoint).

Shared modules in `nix/packages/cococoir/src/` (ADR-024, ported from
Go):

- **`forwarder`** — TCP + UDP forwarding, retry, drain, signal
  handling. ~15 unit tests.
- **`health`** — `/healthz` (always 200), `/readyz` (200 if any
  forward is bound), `/status` (JSON snapshot of forwarder state
  with `component`, `forwards`, `tcp_connections`, `udp_flows`).
  ~9 tests.
- **`logger`** — tracing-based structured logging with `text` and
  `json` formats.

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
- **btrfs-based local storage with encrypted offsite backups.**
  Two drives in a btrfs RAID1 pool; subvolumes per service with
  quotas. Restic pushes encrypted snapshots to the hosted infra
  (the customer's data stays encrypted at rest offsite). No FUSE,
  no S3 API at the service layer — apps get real filesystems.
- **Local OTEL observability.** Prober (HTTP GETs) emits OTEL
  traces; journald tailer emits OTEL logs. In-memory OTEL SDK
  exporter. Embedded dashboard at `:9090` showing services +
  recent probes + recent logs.
- **sops-nix for secrets.** Age-encrypted secrets in the user's
  repo. `nix run .#init` and `nix run .#add-secret` helpers for
  the first-time setup.
- **No multi-tenant, no remote access, no edge.** That's v3.

### Components

#### Storage (NixOS module at `nix/nixos-modules/storage/btrfs.nix`)

v2 storage is **btrfs + restic** (see ADR-023):

- **btrfs RAID1 pool** across two drives. HDD failure → data survives
  (RAID1 keeps 2 copies on any 2 devices, so drives need not match
  in size).
- **btrfs subvolumes** per service (e.g. `tank/media/movies`,
  `tank/cryptpad-data`). Each gets a qgroup quota. Services mount
  these directly — no FUSE, no S3 translation layer.
- **btrfs over ZFS**: drives can be added, removed, or replaced at
  any time (`btrfs device add/remove/replace`); ZFS mirror pairs are
  fixed at pool creation.
- **Restic** (single Go binary, client-side encryption, deduplication,
  compression) runs as a systemd timer. Pushes encrypted snapshots
  to the hosted endpoint (any S3-compatible target — MinIO, Backblaze
  B2, etc. — via rclone). The hosted infra sees only encrypted blobs.
- **Cold spare**: a second machine runs restic server (or just SSH)
  for local resilience. Machine A dies → restic restore on B, rebuild
  from flake, <10 minutes recovery.

#### Services (NixOS modules at `nix/nixos-modules/services/`)

The factory contract (`_contract.nix`):

Every service calls `mkCococoirService` with a 3-line declaration
(name, description, port, optional healthPath/bucket), and the
factory generates: the NixOS option tree (enable/domain/public),
the Caddy vhost with correct TLS, the systemd unit wiring, and
the standard assertions (public → Caddy, bucket → storage, domain).
The contract is enforced by code (ADR-020), not convention —
`contract-conformance` L1 check fails the build on any divergence.

The contract adapts per service class:
- **Metadata-only services** (radarr, sonarr, lidarr, prowlarr):
  3 options — no storage needed. `defaultHealthPath = "/ping"`.
- **Data services** (jellyfin, cryptpad): standard options + the
  factory auto-declares the service's btrfs subvolumes (quota +
  owner set in the module, not by the customer).
- **Infra services** (dex): 3 options — no storage, no health path
  (dex exposes its own /.well-known/openid-configuration).

##### Existing services (7, all built on the factory)

| Service | Port | Health | Subvolume | OIDC-integrated |
|---------|------|--------|-----------|-----------------|
| jellyfin | 8096 | /health | media (movies/shows/music) + metadata | Yes (via jellarr + jellyfin-oidc) |
| cryptpad | 3000 | /checkup/ | cryptpad-data | Yes (via cryptpad-oidc) |
| radarr | 7878 | /ping | — | — |
| sonarr | 8989 | /ping | — | — |
| lidarr | 8686 | /ping | — | — |
| prowlarr | 9696 | /ping | — | — |
| dex | 5556 | (self) | — | — (the OIDC provider itself) |

##### Auth: Dex-only OIDC (see ADR-021)

Dex is the sole OIDC provider. Users are declared in
`cococoir.services.dex.staticPasswords` (a Nix attrset of
username → bcrypt-hash). No PocketID, no Authentik, no admin
dashboard — just a config file. The customer sets an admin
user at provisioning time and can add more users by editing
the config (which is a `nixos-rebuild` away). For v2's scale
(<5 users per box), this sidesteps the "OIDC provider needs
its own user management" problem entirely — Dex doesn't need
a separate database, it just reads the hash from config.

Services are wired to Dex declaratively:
- `jellyfin-oidc.nix`: installs the OIDC RBAC plugin DLLs,
  generates a client secret on first boot (oneshot), adds
  the Jellyfin client to Dex's staticClients, configures
  jellarr with Dex as the OIDC provider.
- `cryptpad-oidc.nix`: similarly for CryptPad SSO.
- The `vmtest-wiring` L1 check asserts both integrations
  survive module composition (no mkForce/optionalAttrs dropping
  them from the rendered config).

Both integrations auto-activate when their parent service and Dex
are both enabled — the customer sees one toggle ("enable jellyfin")
and gets OIDC for free. No `cococoir.integrations.X.enable` option
exists.

##### Planned services

- **Nextcloud** (v2.3): btrfs subvolume storage. OIDC via Dex.
- **qBittorrent** (v2.13): shared `media` volume.
- **Jellyseerr** (v2.13): request management, OIDC via Dex.

#### cococoir-client extensions (Rust)

The `cococoir-client` binary (v0, Rust) gets three new modules:

- **`probe`** — HTTP GET prober, periodic (default 60s),
  one OTEL span per probe: `{name: "probe <url>", kind: CLIENT,
  attributes: {http.url, http.status_code, http.method}, status:
  OK/ERROR, duration: <measured>}`. Reads `services` list from the
  cococoir config.
- **`journald`** — tails `systemd` journal for each
  service's declared units. Emits one OTEL log record per entry:
  `{time, observed_time, severity_number, severity_text, body,
  attributes: {pid, exe, unit}}`. Reads `services.<name>.journald.units`
  from config.
- **`otel`** — wires the OTEL SDK. `tracerProvider` and
  `loggerProvider` configured with a custom in-memory exporter
  (capped slices for the dashboard). OTLP exporter configured but
  pointed at a non-existent endpoint for v2 (edge export is v3).

The existing `health` server grows three new endpoints:
`/` (HTML dashboard), `/api/probes` (recent probe results as JSON),
`/api/logs` (recent log records as JSON). The existing
`/healthz`, `/readyz`, `/status` endpoints stay.

The forwarder (`forwarder`) does not change for v2. It
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

HTML and JS are embedded in the Rust binary via `include_str!` /
`include_bytes!`. The
binary serves the dashboard at `:9090/` and the JSON endpoints at
`:9090/api/{probes,logs}`. No external dependencies. No build step.

#### sops-nix helpers (Nix flake apps)

Two `nix run` commands at the flake root:

- `nix run .#init` — generates an age keypair if missing, creates
  an encrypted `secrets.yaml` template with random values for every
  key in the secret inventory (`jellarr-api-key`,
  `jellyfin-admin-password`; see `nix/nixos-modules/secrets.nix`),
  prints the public key for committing
  to `.sops.yaml`, and tells the user to commit and rebuild.
- `nix run .#add-secret <name>` — prompts for a single secret
  value, encrypts it, and adds it to the encrypted file.

Both run the standard `sops` CLI with the user's age key. The
flake provides the right command-line flags for the encrypted
file's path and key.

#### vmtest-e2e (the v2 gate)

`scripts/vmtest-e2e.sh`. Nukes `vmtest.qcow2`, rebuilds the
`vmtest` nixosConfiguration (`nixosConfigurations/vmtest.nix`:
Jellyfin + dex + cryptpad + btrfs + sops), boots headless, and
runs the assertion suite (`scripts/vmtest-bootstrap.sh`):

1. **Boot**: the btrfs pool + subvolumes are created, each service
   subvolume is writable by its owner, all services are active,
   jellarr applied its config (the Jellyfin login page renders
   "Sign in with Dex").
2. **Auth**: Dex OIDC discovery responds; CryptPad SSO `/ssoauth`
   returns a JWT.
3. **Secrets**: build-time-generated secrets land at the right
   paths with the right permissions.

The test is hermetic: it generates its own secrets and uses two
virtual disks for the pool. No external network calls. This is the
**v2 gate** — the thing that has to pass for v2 to ship.

### Architecture rules

These are the rules v2 enforces. They are non-negotiable.

- **L4 forwarder has no service knowledge.** The forwarder reads
  `forwards = [...]` from config; it does not know about storage,
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
- **3-option (or 4-option) service contract is enforced by the factory, not by hand.**
  `mkCococoirService` from `_contract.nix` owns the standard option surface
  (enable / domain / public), the Caddy vhost, and the standard assertions.
  Adding a 5th option requires careful justification; the factory provides
  `extraConfig` for per-service additions without breaking the contract. See ADR-020.
- **Native filesystem > S3 > FUSE.** Services get btrfs subvolumes
  (real filesystems) as their data directories. S3 is a v4 cluster
  concern. FUSE is the fallback for services that need a specific
  path shape, not a v2 design goal.

## v3 — Control plane (deferred)

The piece that replaces "operator edits git" with a real backend.
Rust service + Postgres + HTTP API + web UI. Triggered when the
operator workflow gets painful at 10-20 customers.

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
  surface minimal for the non-technical customer. *Extended by
  ADR-020: the factory now enforces this by code.*
- **ADR-005: Native filesystem > S3 > FUSE — superseded by ADR-023.**
  Originally: services with a native S3 backend (Nextcloud) use S3;
  FUSE-mounting a bucket is the fallback. *Superseded by ADR-023
  for v2: btrfs subvolumes (native filesystems) are the primary
  storage; S3 is a v4 cluster concern; FUSE is last resort.*
- **ADR-006: TLS keys never leave the box.** Caddy on the customer
  box owns TLS. The forwarder is L4 and never decrypts. The
  customer's x25519 keys only exist on their local device.
- **ADR-007: L4 forwarder has no service knowledge.** The
  forwarder reads `forwards = [...]` from config. It does not
  know about storage, S3, or any service. Service logic lives in
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
- **ADR-017: Go service is the spine of v2 — superseded by ADR-024.**
  Bounded scope: L4 forwarder + prober + journald tailer + OTEL SDK +
  embedded dashboard. No control plane in Go (that's v3's separate
  service). No service logic in Go (services are NixOS modules). *The
  bounded-scope statement survives; only the language changed — see
  ADR-024.*
- **ADR-018: Config generation via `environment.etc` + `builtins.toJSON`.**
  Module `configFile` defaults to `/etc/cococoir-{edge,client}.json`.
  Operators can override with a custom path.
- **ADR-019: bbolt for per-VPS storage at `/var/lib/cococoir/edge.db`.**
  v0 ships bbolt. v2's bbolt usage is the same (no schema change
  in this slice). Badger was rejected as more complex with no
  benefit at this scale.
- **ADR-020: Factory contract enforces the service contract.**
  Every service module calls `mkCococoirService` from
  `_contract.nix` with a 3-line declaration. The factory generates
  the option tree, Caddy vhost, systemd wiring, and standard
  assertions. The `contract-conformance` L1 check fails the build
  if any service module diverges from the factory. Rejected
  alternatives: convention (ADR-004's 4-option convention without
  enforcement — led to drift in the prior pocket-id module);
  per-service boilerplate (high duplication, silent-failure seams).
- **ADR-021: Dex is the sole OIDC provider; PocketID is removed.**
  Dex with `staticPasswords` handles all three requirements for v2:
  (1) standard username/password auth, (2) admin user set in config
  file (recovery path), (3) low resource overhead (~30MB). PocketID
  was removed — it duplicated OIDC provider functionality without
  adding password support, and the Dex-only chain (Dex → Jellyfin)
  is one hop instead of two (PocketID → Dex → Jellyfin). Rejected:
  Authentik (300MB+ RAM, overkill), PocketID (no password support,
  redundant hop), LDAP (heavier protocol, less service support).
- **ADR-022: L1 checks are structural tripwires, not style tests.**
  `contract-conformance` asserts every service module uses the
  factory (grep source). `doc-refs` asserts every referenced path
  in AGENTS.md/PLAN.md/STATUS.md exists + every ADR cited in
  module comments exists in PLAN.md. `vmtest-wiring` evaluates the
  real vmtest nixosConfiguration and asserts OIDC integration
  config (plugins, branding, boot activation) survives module
  composition — catches the regression class where mkForce or
  optionalAttrs on config silently drops the integration. All three
  run as pure eval checks (L1); all three gate `nix flake check`.
- **ADR-023: btrfs + restic replaces Garage+FUSE for v2 storage.**
  v2's single-node deployment cannot benefit from Garage's
  3-node replication. A btrfs RAID1 pool provides HDD-failure
  resilience without cluster complexity; btrfs subvolumes give each
  service a quota'd virtual filesystem without FUSE overhead;
  restic provides client-side-encrypted offsite backups to the
  hosted infrastructure.
  btrfs over ZFS: drives can be added, removed, or replaced at any
  time (`btrfs device add/remove/replace`) and mixed drive sizes
  work (RAID1 keeps 2 copies on any 2 devices, not fixed mirror
  pairs), so growing storage is a hot operation instead of a pool
  rebuild.
  Garage was deleted entirely (v1 retained in archive/); resurrect
  from git history for v4 multi-machine support if needed.
  Rejected: ZFS (fixed mirror pairs; drive add/remove requires
  pool-level surgery), single-drive + cloud-only backup (fails the
  "survive HDD failure locally" requirement), distributed fs
  (Ceph/Gluster — far too heavy for a single ARM board).
  *Implemented 2026-07-31: `storage/btrfs.nix` — pool creation
  (idempotent oneshot), subvolume management with quota + owner,
  service auto-declaration, auto-scrub, zstd compression.
  Fresh-boot verified 2026-07-31 + 2026-08-01.*
- **ADR-024: The cococoir service is Rust, not Go (supersedes
  ADR-017's language).** The entire Go role — forwarder, edge/client
  mains, health server, logger — is ported to a single Rust crate
  (`nix/packages/cococoir`). The CLI flags, config JSON schema,
  binary names, and `/status` JSON contract are unchanged, so the
  systemd modules and the `edge-forward` L2 test needed no edits.
  Rationale (see `writing/llm/rust-rewrite.md`): schema/type modeling
  for the v2+v3 config-agent thesis, the LLM compile-time feedback
  loop, and boundary strictness on untrusted telemetry input. The
  usual justifications — memory safety, performance — are a wash and
  were explicitly rejected. `internal/store` (bbolt, orphaned) was
  deleted, not ported: nothing imported it, and v3's control plane
  targets Postgres. The port is verified by the L2 `edge-forward`
  nixosTest (`edge-forward: PASS`), which now runs against the Rust
  binaries.

## Implementation backlog

Build order. No dates. Each item: what it produces, what test
verifies it. "Done" = shipped, tested, committed.

### v0 — L4 forwarder (done)

- Forwarder: TCP+UDP, retry, drain, signal handling. **Tests:**
  `forwarder` Rust unit tests (29 total across the crate), 2-VM
  nixosTest data-path. (Ported from Go, ADR-024.)
- Health endpoint: `/healthz`, `/readyz`, `/status`. **Tests:**
  `health` Rust unit tests, 2-VM nixosTest health assertions.
- Structured logging: tracing, text/json formats, per-component
  span. **Tests:** `logger` Rust unit tests.
- bbolt store: `internal/store` **deleted with the Go port** — it had
  no consumers; v3's control plane targets Postgres (ADR-024).

### v2 — Home server (in progress)

**Built (7 service modules, factory contract, OIDC integrations):**

- **Services**: jellyfin, cryptpad, dex, radarr, sonarr, lidarr,
  prowlarr — all via the `_contract.nix` factory. `contract-conformance`
  L1 check gates every service module.
- **OIDC**: Dex is the sole provider. jellyfin-oidc integration
  (jellarr + OIDC RBAC plugin) auto-activates when jellyfin + dex
  are enabled. cryptpad-oidc similarly for CryptPad SSO.
  `vmtest-wiring` L1 check asserts OIDC survives module composition.
- **Storage**: btrfs pool + subvolumes (see ADR-023), verified on
  fresh boots 2026-07-31 + 2026-08-01.
- **L1 test infrastructure**: `contract-conformance` (factory usage),
  `doc-refs` (doc path validity + ADR cross-check),
  `vmtest-wiring` (OIDC integration presence in rendered config).
- **L0**: forwarder Rust unit tests (v0, shipped — 42 tests via
  `cargo test`).

**P0 — blocked:**

- **jellarr fails on fresh boot**: jellarr starts ~3s after
  jellyfin restart and dies with `ECONNREFUSED 127.0.0.1:8096`.
  Jellyfin health was 502 at the time. Either crash-looping
  (check journal for OIDC plugin DLLs) or preStart readiness
  probe racing the restart. Reproduce: `scripts/vmtest-e2e.sh`.
  Nothing else ships until this is green.

**Remaining v2 work (ordered):**
- **v2.p0**: Fix P0 jellarr boot bug. Gate: `vmtest-e2e.sh` PASS.
- **v2.storage** (done 2026-07-31): btrfs pool + subvolume
  management replaces Garage+FUSE. Garage files, FUSE services,
  and 5 S3 secrets deleted; the earlier ZFS attempt was replaced
  by btrfs for hot drive add/remove. New `storage/btrfs.nix`
  creates the pool via idempotent oneshot; services auto-declare
  subvolumes with quotas + owners. Fresh-boot verified 2026-07-31
  + 2026-08-01; L2 e2e still blocked by P0 jellarr.
- **v2.restic**: restic encrypted offsite backup. rclone backend
  (S3/B2/rsync), password from secrets, timer on btrfs subvolumes.
- **v2.nextcloud**: Nextcloud service module with btrfs subvolume
  storage + OIDC via Dex.
- **v2.probe**: `cococoir-client internal/probe` — HTTP GET
  prober reading services list from config, emitting OTEL spans.
- **v2.journald**: `cococoir-client internal/journald` — tails
  systemd journal per service, emits OTEL log records.
- **v2.otel**: OTEL SDK wiring (in-memory exporter).
- **v2.dashboard**: Embedded HTML/JS dashboard serving probe +
  log data.
- **v2.cryptpad-password**: Decide the CryptPad SSO password default.
  `settings.sso.cpPassword = true` now — users may set a personal
  encryption password at registration or later via Settings → Account
  → Own your drive (skip → admin-readable keys). Decided: **optional
  (`cpPassword=true`, not forced)** so forgotten passwords never lock
  the admin out of recoverable data. Verified via vmtest-bootstrap
  (served `sso.password` == 1).
- **v2.sops**: `nix run .#init` + `nix run .#add-secret` helpers.
- **v2.gate**: 1-VM nixosTest combining storage + services + OIDC.
- **v2.arr**: qBittorrent + Jellyseerr (shared media volume).
- **v2.sanitize**: PII sanitization for OTEL export.
- **v2.otel-backend**: Decide between embedded dashboard, Grafana, or both.

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
