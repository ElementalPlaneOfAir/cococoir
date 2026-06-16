# THE GREAT SIMPLIFICATION

A working document for the cococoir tech-debt reduction. Captures the
audit conclusions, the decisions made, the trim plan, and the current
state. After a session break, read this file first.

## Goal

Reduce cococoir from a sprawling, speculative "library" to a tight
deployment tool that:
- Solves real problems for actual client deployments (not hypothetical
  ones).
- Exposes the minimum config surface needed (4-option service contract).
- Always prefers native S3 backends; FUSE (geesefs) is the fallback.
- Keeps the project auditable: a single person (nicole) can hold the
  whole thing in their head.

## Foundational decisions

### 1. Cococoir is a deployment tool for client installs (not a generic library)

Evidence: 1 consumer (amon-sul) today, but the design point is *new
client onboarding*. Every line of "library surface area" (per-service
module files, exports, version compatibility) is a tax paid per change.

Trim posture: keep the flake input shape, but don't ship a separate
"API contract" for imaginary future consumers. If a new client needs
something, add it then.

### 2. The VPS + rathole + terraform stack is a separate project

Not every client needs it. The custom tunnel (vs Cloudflare / Tailscale
Funnel) is justified because TLS keys stay on the home server (privacy
property clients care about). But it's a separate concern that should
not be spun up for every client.

Path: move `terraform/`, `modules/proxy/{client,server}.nix`, and the
`sops/machines/ionos-vps` key to a `tunnel/` directory in this repo
with a different tech stack. Phase 4.

### 3. Service catalog: "fully integrated with Garage S3" is the gate

A service stays in cococoir iff its state can live in (or be backed up
to) a Garage S3 bucket — i.e. data is portable, the service survives a
machine rebuild.

Priority services (user-confirmed):
- **Add**: Nextcloud (native `objectstore.s3` backend), Cryptpad
  (FUSE-mounted dataPath).
- **Keep**: Jellyfin, Threadfin (via `custom`), qBittorrent, autobrr,
  Jellyseerr, media-stack helper, Matrix, mautrix-gmessages.
- **Delete**: Vaultwarden, Forgejo, Kavita, OctoPrint (no S3
  integration, no client demand).

### 4. Native S3 over FUSE, always

For services that have a native S3 backend (Nextcloud's
`objectstore.s3`), use it. FUSE-mounting a bucket as a service's
data dir is the fallback for services without native S3 support
(Cryptpad, Jellyfin, qBittorrent downloads).

The "fully integrated with S3" criterion is satisfied by EITHER path —
native integration OR FUSE-mounted bucket. Native is preferred.

### 5. Minimal service option contract

Every service module exposes exactly these options, no more:

| Option | Type | When |
|---|---|---|
| `enable` | bool | always |
| `domain` | str | always |
| `public` | bool | always |
| `bucket` | str | only for S3-using services |

No `port`, `signupsAllowed`, `openFirewall`, `host`, `https`,
`secretFile`. The module picks sensible defaults, binds to
`127.0.0.1`, and delegates to clan-core vars for secrets. The deployer
is non-tech-savvy; minimal config is the right default.

`cococoir.services.custom.<name>` is the *only* exception — it adds
`port` (the deployer picks the listen port for the arbitrary service).

## Storage design (cococoir/garage clan.service)

Single-node primary path. Multi-node is a future exercise; the
clan.service shape is preserved so it can grow into that, but the
machinery for it is not shipped today.

### Architecture

- **clan.service** at `clan-services/garage/default.nix` (305 LOC).
- **Static bucket-init script** at `clan-services/garage/bucket-init.sh`
  (no string interpolation in Nix; takes `buckets.json` and
  `global-dir` as args; receives `CLAN_VAR_S3_KEY_DIR` as env).
- **FUSE mounts** declared via `fileSystems.<path>.fsType =
  "fuse.geesefs"` — NixOS generates the mount units. The
  `After/Requires` on the bucket-init service is added via
  `systemd.services.<mount>.mount` overrides.
- **Disko helper** at `lib/garage-data-disko.nix` — pure function for
  users with custom data-drive layouts. The clan-service also
  accepts an inline `dataDevice` option for the simple case.
- **Clan vars**:
  - `garage-rpc-secret` (`share = true`): cluster-wide RPC secret.
  - `garage-global-s3-key` (`share = true`): the S3 access key +
    secret. Pre-generated so native-S3 clients with eval-time configs
    (Nextcloud's `objectstore.s3.key`) can read it via
    `builtins.readFile`.
  - `garage-admin-token`, `garage-metrics-token` (per-node).
- **Derived view** (`cococoir.storage.derived.*`):
  - `gatewayAddress` — e.g. `"127.0.0.1:3900"`.
  - `buckets.<name>.{name, endpoint, host, port, region,
    accessKeyIdFile, secretAccessKeyFile}` — for native-S3 clients.
- **Hardened garage systemd unit**: `LoadCredential=` for the three
  secrets, `Environment=GARAGE_RPC_SECRET_FILE=%d/rpc_secret` (and
  friends), `DynamicUser=mkForce false`, static `garage` user. No
  placeholder+sed hack.

### Why the S3 key is a clan var, not generated at runtime

Nextcloud's `services.nextcloud.config.objectstore.s3.key` is
interpolated into the PHP config at evaluation time (line 220 of
`nixos/modules/services/web-apps/nextcloud.nix`: `'key' => '${s3.key}'`).
If the key is generated at runtime, the Nix module can't read it.

Pre-generating the key as a `share = true` clan var means:
- `clan vars generate` produces it once.
- Nix reads it via `builtins.readFile` at evaluation time.
- The bucket-init script imports it into garage on first boot.
- Every node in the cluster (when we get there) has the same key.

This is the standard clan-core pattern; the only unusual bit is that
Nextcloud's config forces the key to be known at eval time.

### Why a separate bucket-init script

The bucket-init script has runtime logic (idempotent key import, layout
apply, bucket create / allow / set-quota / website) that doesn't belong
in Nix. Embedding it as a Nix `''` string with `${...}` interpolation
is unreadable and unmaintainable. The script is a regular `.sh` file,
Nix generates the JSON config, the systemd service wires them together.

### Multi-node: not shipped, not blocked

The clan.service has a `node` role. Single-machine deployment = one
machine in `roles.node.machines`. Multi-machine deployment = multiple
machines. The `bootstrap_peers` auto-derivation and per-node
`address` setting are the foundation; what we'd add later is:
- `roles.node.machines.<name>.settings.zone` and a `layout.zones`
  option for capacity-weighted placement.
- Eval-time assertions for `replicationFactor > numZones`.
- Multi-node key distribution (currently the global S3 key is local
  on each node; multi-node would need a sync mechanism).

Don't ship this machinery until a client needs it.

## Trim plan (phases 0–6)

| # | Phase | Status |
|---|---|---|
| 0 | Commit/revert garage WIP for a clean baseline | **DONE** (commit `f6176f9` is the baseline; WIP was stashed and superseded) |
| 1 | Pure deletions: Vaultwarden, Forgejo, Kavita, OctoPrint, cli/; AGENTS.md catalog trim; minimal-option contract codified | **DONE** (commit `5b3666a`) |
| 2 | Replace legacy `modules/storage*` with `clan-services/garage/` clan.service (single-node, declarative FUSE, S3 key as clan var) | **DONE** (commit `5043dbe`) |
| 3 | Add Nextcloud module (native `objectstore.s3`); flesh out Cryptpad (FUSE-mounted dataPath) | **DONE** (commits `f0f35b2` Nextcloud, this commit Cryptpad) |
| 4 | Move `terraform/` + `modules/proxy/` to `tunnel/` directory (separate tech stack) | NOT STARTED |
| 5 | Final `nix flake check` + AGENTS.md pass; ensure no orphan references to deleted services, rathole, CLI, multi-node garage | NOT STARTED |
| 6 | Update `amon-sul` to use new cococoir shape | NOT STARTED (separate session) |

## Current state (after Cryptpad lands; will be replaced with a commit hash on commit)

### What works
- `nix flake check` passes.
- Cococoir flake exposes:
  - `nixosModules.default` — `import-tree ./modules` (auth, base,
    core, caddy, services).
  - `nixosModules.{core,auth,base,caddy}` — individual modules.
  - `clan.modules."cococoir-garage"` (via `clan-services/garage/flake-module.nix`) — the
    clan.service. Consumers add this to their inventory.
  - `flake.lib.mkGarageDataDisko` — the disko helper.
  - `devShells.default` — `opentofu` + `jq`.
- Service catalog: Jellyfin, qBittorrent, autobrr, Jellyseerr, Matrix,
  mautrix-gmessages, **Nextcloud** (native S3), **CryptPad**
  (FUSE-mounted dataPath), and the `custom` escape hatch. All 4-option
  contract. All S3-backed (native or FUSE).

### What's uncommitted (in working tree, NOT yet committed)
The Cryptpad work is in the working tree but uncommitted. Files:
- `clan-services/garage/default.nix` — added `derived.mounts` keyed by
  bucket name, so service modules can resolve a FUSE mount point via
  `cococoir.storage.derived.mounts.${cfg.bucket}.mountPoint`.
- `modules/services/cryptpad.nix` — fleshed out from a 42-LOC stub to
  a full 4-option module: `enable`/`domain`/`public`/`bucket`. Sets
  `services.cryptpad.settings.filePath` to the derived mount point,
  asserts the mount exists at eval time, disables telemetry
  (`blockDailyCheck = true`), and creates the mount-point dir owned by
  the `cryptpad` user via tmpfiles. Keeps the established
  `localNetworks` 403 pattern for non-public deployments (matches 7/9
  service modules; the only exception is nextcloud, which does its own
  auth via an admin password).

### Decisions logged this session
- **FUSE mount ownership** (open question #1, resolved): garage owns
  mounts; service modules consume the derived path. Concretely:
  `cococoir.storage.derived.mounts` is keyed by bucket name (not mount
  name), so a service that knows its `bucket` can resolve the mount
  point with one attribute lookup. If the bucket has no mount, the
  module fails to evaluate with a clear error pointing at the
  `mounts.<name>` declaration the user needs to add. Same pattern
  will apply to any future FUSE-backed service (e.g. jellyfin's
  library, qBittorrent downloads — both currently lack a `bucket`
  option, which is a follow-up).

### What's pending
- **Phase 4** (move terraform + rathole to `tunnel/`).
- **Phase 5** (final flake check + AGENTS.md pass — AGENTS.md still
  references rathole, vaultwarden (deleted), the CLI section
  (removed), and the legacy storage module (removed)).
- **Phase 6** (amon-sul consumer update).
- **Follow-up (out of phase scope)**: jellyfin and qbittorrent
  service modules should also take a `bucket` option and use the
  derived mount path for their data / downloads dir. Same pattern as
  cryptpad. This is a phase-5+ cleanup; not blocking phase 3.

## Key design notes

### clan.service import pattern

Import-tree picks up `.nix` files recursively, but a clan.service
module (`_class = "clan.service"`) cannot be imported as a
flake-parts module (`_class = "flake"`). Solution: use a
hand-rolled import in `flake.nix` that only imports each
subdirectory's `flake-module.nix`, not the `default.nix`. Same
pattern as `clan-core`'s `clanServices/flake-module.nix`.

### `builtins.readFile` on clan var paths

The Nextcloud module reads the S3 access key from a clan var path
via `builtins.readFile`. This is lazy — it only fails when forced.
For `nix flake check` (which doesn't enable the module), the read is
never forced, so the check passes. For real deployments, the
deployer must run `clan vars generate` (or `clan machines update`)
before `nixos-rebuild` to produce the var file.

### Why a single `systemd.services` block in the garage clan-service

Mixing `systemd.services.garage.serviceConfig = {...}` (deep path)
with `systemd.services = lib.mapAttrs' ...` (whole attrset) in the
same `config` causes "attribute already defined" errors. Fix: put
everything in a single `systemd.services = { garage = ...; garage-bucket-init = ...; } // mountDeps;`.

### Why delete `flake-vars/`

The per-service clan vars (`storageVars`, etc.) were a hand-rolled
way to expose clan-core generators. The clan.service pattern
supersedes it: each clan.service module declares its own generators
inline via `clan.core.vars.generators.<name> = { ... }`. No more
import-tree on `flake-vars/`.

## File map (after phase 5)

```
cococoir/
├── flake.nix
├── lib/
│   └── garage-data-disko.nix
├── clan-services/
│   └── garage/
│       ├── default.nix          # the clan.service (305 LOC)
│       ├── bucket-init.sh       # the runtime script
│       └── flake-module.nix     # registers clan.modules."cococoir-garage"
├── modules/
│   ├── auth.nix
│   ├── base.nix
│   ├── core.nix
│   ├── networking/
│   │   └── caddy.nix
│   └── services/
│       ├── autobrr.nix
│       ├── cryptpad.nix         # to be fleshed out (phase 3)
│       ├── custom.nix
│       ├── jellyfin.nix
│       ├── jellyseerr.nix
│       ├── matrix.nix
│       ├── mautrix-gmessages.nix
│       ├── media-stack.nix
│       ├── nextcloud.nix        # NEW (phase 3)
│       └── qbittorrent.nix
├── tunnel/                      # NEW (phase 4)
│   ├── README.md
│   ├── terraform/               # moved from ./terraform/
│   └── nix/                     # moved from ./modules/proxy/
├── AGENTS.md
├── THE_GREAT_SIMPLIFICATION.md  # this file
└── LICENSE
```

## Open questions

1. **FUSE mount ownership** *(RESOLVED)*: garage owns mounts; service
   modules consume the derived path. `cococoir.storage.derived.mounts`
   is keyed by bucket name. See "Decisions logged this session" above.
2. **Tunnel project tech stack**: when we move rathole + terraform
   to `tunnel/`, what tech stack does the new project use?
   *Recommendation: keep OpenTofu (the existing `terraform/` is
   already OpenTofu-flavored); the Nix `modules/proxy/` modules
   become a separate flake under `tunnel/nix/`.*
3. **`vaultwarden` / `forgejo` / `kavita` / `octoprint` deletion
   audit**: any of these have client demand? If yes, bring them
   back as proper S3-backed modules. If no, deletion is final.

## Session compact instructions

After a session break:
1. Read this file end-to-end.
2. Check `git log --oneline -10` for the latest commits.
3. Check `git status` for uncommitted work (Nextcloud, Cryptpad).
4. Continue from the "What's in progress" section.
