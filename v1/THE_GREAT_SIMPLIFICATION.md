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
| 4 | Move `terraform/` + `modules/proxy/` to `tunnel/` directory (separate tech stack) | **DONE** (this commit — see "Phase 4 changes" below) |
| 5 | Final `nix flake check` + AGENTS.md pass; ensure no orphan references to deleted services, rathole, CLI, multi-node garage | NOT STARTED |
| 6 | Update `amon-sul` to use new cococoir shape | NOT STARTED (separate session) |

## Current state (after phase 4 lands; will be replaced with a commit hash on commit)

### Phase 4 changes

- **`tunnel/` is now a separate sub-flake**, not a subdirectory of the
  cococoir flake. It has its own `flake.nix` (depends on `nixpkgs`
  only — no `clan-core`, no `vpn-confinement`) and its own
  `flake.lock` once initialized. Lives in the same git repo
  (monorepo) but is consumable as a separate input by deployment
  repos (`tunnel.url = "path:./tunnel"` or
  `github:.../cococoir?dir=tunnel`).
- **`terraform/` → `tunnel/terraform/`**. All modules and the
  `examples/basic/` worked example moved verbatim; relative paths
  inside the terraform tree are unchanged.
- **`modules/proxy/{client,server}.nix` → `tunnel/nix/{client,server}.nix`**.
  Option namespace changed from `cococoir.proxy.{client,server}` to
  `tunnel.{client,server}` (it was always a leaky namespace — the
  proxy options never belonged under `cococoir.*`). This is a
  **breaking change** for the amon-sul consumer, which currently sets
  `cococoir.proxy.client.*`. The migration is on the phase-6 list
  (update amon-sul).
- **`sops/machines/ionos-vps/` → `tunnel/sops/machines/ionos-vps/`**.
  The amon-sul sops keys stay where they are. Any deployment repo
  that references the VPS age key by path needs to update the path.
- **`tunnel/flake.nix` exposes** `nixosModules.client` and
  `nixosModules.server` (the rathole modules) and a dev shell with
  `opentofu` + `jq`.
- **`tunnel/README.md`** documents the project structure and the
  "monorepo with separate flake" rationale.
- **`AGENTS.md`** was updated for the direct broken references (file
  map's rathole entries, Infrastructure Provisioning section). The
  full AGENTS.md pass (legacy storage section, CLI section, etc.)
  is still phase 5.

### What works
- `nix flake check` passes.
- Cococoir flake exposes:
  - `nixosModules.default` — `import-tree ./modules` (auth, base,
    core, caddy, services). `import-tree` no longer picks up
    `modules/proxy/` because that directory is gone.
  - `nixosModules.{core,auth,base,caddy}` — individual modules.
  - `clan.modules."cococoir-garage"` — the garage clan.service.
    Consumers add this to their inventory.
  - `flake.lib.mkGarageDataDisko` — the disko helper.
  - `devShells.default` — `opentofu` + `jq` (kept for now; could
    move to `tunnel/flake.nix` only — see phase 5 cleanup).
- Tunnel flake (separate input) exposes:
  - `nixosModules.client`, `nixosModules.server` — rathole modules.
  - `devShells.<system>.default` — `opentofu` + `jq`.
  - `terraform/` — OpenTofu modules, consumed directly (no flake).
- Service catalog: Jellyfin, qBittorrent, autobrr, Jellyseerr, Matrix,
  mautrix-gmessages, Nextcloud (native S3), CryptPad (FUSE-mounted
  dataPath), and the `custom` escape hatch. All 4-option contract. All
  S3-backed (native or FUSE).

### What works
- `nix flake check` passes.
- Cococoir flake exposes:
  - `nixosModules.default` — `import-tree ./modules` (auth, base,
    core, caddy, services). `import-tree` no longer picks up
    `modules/proxy/` because that directory is gone.
  - `nixosModules.{core,auth,base,caddy}` — individual modules.
  - `clan.modules."cococoir-garage"` (via `clan-services/garage/flake-module.nix`) — the
    clan.service. Consumers add this to their inventory.
  - `flake.lib.mkGarageDataDisko` — the disko helper.
  - `devShells.default` — `opentofu` + `jq` (kept for now; could
    move to `tunnel/flake.nix` only — see phase 5 cleanup).
- Tunnel flake (separate input) exposes:
  - `nixosModules.client`, `nixosModules.server` — rathole modules.
  - `devShells.<system>.default` — `opentofu` + `jq`.
  - `terraform/` — OpenTofu modules, consumed directly (no flake).
- Service catalog: Jellyfin, qBittorrent, autobrr, Jellyseerr, Matrix,
  mautrix-gmessages, Nextcloud (native S3), CryptPad (FUSE-mounted
  dataPath), and the `custom` escape hatch. All 4-option contract. All
  S3-backed (native or FUSE).

### What's uncommitted (in working tree, NOT yet committed)
The phase 4 work is in the working tree but uncommitted. Files:
- `terraform/` → `tunnel/terraform/` (renamed).
- `modules/proxy/{client,server}.nix` → `tunnel/nix/{client,server}.nix`,
  with the option namespace changed from `cococoir.proxy.*` to
  `tunnel.*`. `modules/proxy/` is removed.
- `sops/machines/ionos-vps/` → `tunnel/sops/machines/ionos-vps/`.
  `sops/machines/amon-sul/` stays in place.
- `tunnel/flake.nix` — new file; separate flake, nixpkgs-only input.
- `tunnel/README.md` — new file; documents the project.
- `tunnel/terraform/README.md` — updated to reflect the new path
  (`cd examples/basic`, `tofu init`).
- `AGENTS.md` — removed the rathole entries from the file map,
  removed "VPN tunneling" from the description, added a pointer to
  the tunnel/ sub-project, replaced the Infrastructure Provisioning
  section with a one-liner pointing at tunnel/README.md.

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
- **Tunnel option namespace**: `tunnel.{client,server}` not
  `cococoir.proxy.*`. Tunnel is its own project; the old namespace
  was always a leak. Breaking change for amon-sul; that update is
  on the phase-6 list.
- **Tunnel as a separate flake inside the monorepo**: confirmed as
  the right structure. Each sub-project gets its own inputs and
  lockfile; the cococoir lockfile stays small (no opentofu noise
  for cococoir-only consumers — though the cococoir dev shell
  itself still has opentofu/jq, which is a phase-5+ cleanup item).

### What's pending
- **Phase 5** (final flake check + AGENTS.md pass — AGENTS.md still
  references the legacy storage module and has a stale "Caddy dev
  shell" line; the dev shell's opentofu/jq is now duplicated in
  tunnel/flake.nix).
- **Phase 6** (amon-sul consumer update — switch rathole from
  `cococoir.proxy.*` to `tunnel.*`, add tunnel flake as an input,
  add the new `bucket` options to jellyfin and qbittorrent, drop
  the references to deleted services, switch the deleted
  qbittorrent / jellyseerr options).
- **FUSE-backed jellyfin / qbittorrent follow-up** *(DONE this session)*.

#### FUSE-backed jellyfin / qbittorrent follow-up — what changed

- **`modules/services/jellyfin.nix`** now takes a `bucket` option.
  The NixOS module does not actively use the bucket: Jellyfin's
  library directories are configured at runtime in the admin UI.
  The `bucket` option exists so the module can assert the FUSE
  mount is declared in the cococoir/garage clan-service — if the
  user forgets the mount, evaluation fails with a clear error
  pointing at the declaration they need to add. The mount path
  can then be referenced as the library root in the admin UI.
- **`modules/services/qbittorrent.nix`** now takes a `bucket`
  option. The download save path is derived as
  `<mountPoint>/downloads`. The old `downloadDir` option is
  removed — qBittorrent is a fully-S3-backed service in cococoir;
  non-S3 use cases should configure qBittorrent outside this
  module. The mount-existence assertion is the same pattern as
  jellyfin / cryptpad.
- **Torrent native-S3 investigation**: qBittorrent, Deluge,
  Transmission, rTorrent — none have native S3 backends. They are
  all file-based clients that write to a local filesystem path.
  FUSE via `geesefs` is the only viable path. The user accepts
  this.

#### Options audit — pass-throughs removed *(DONE this session)*

An audit of every `cococoir.*` option against actual consumer usage
in `amon-sul` removed options that were just pass-throughs to
nixpkgs defaults (no consumer overrode the default), or
"future-proofing" options with no real consumer. Hardcoded values
match the nixpkgs default — if a real need appears, add the option
back.

**Service modules:**

- `cococoir.services.jellyseerr.configDir` removed (default was
  `/var/lib/jellyseerr`, matches nixpkgs `services.seerr.configDir`).
- `cococoir.services.qbittorrent.peerPort` removed (default was
  51413, matches nixpkgs `services.qbittorrent.torrentingPort`).
  The redundant `Connection.PortRangeMin = cfg.peerPort` override
  is also gone (nixpkgs sets it from `torrentingPort` already).
- `cococoir.services.qbittorrent.webuiPort` removed (default was
  8080, matches nixpkgs `services.qbittorrent.webuiPort`).
  `media-stack.nix` now hardcodes `qbtWebuiPort = 8080` and
  `qbtPeerPort = 51413` (same constants, kept in sync by a comment).

**Tunnel modules:**

- `tunnel.client.serverPort` removed (default was 2333, rathole
  standard). Hardcoded in `client.nix`.
- `tunnel.server.controlPort` removed (default was 2333, rathole
  standard). Hardcoded in `server.nix` (firewall + bind_addr).

**Garage clan-service:**

- `s3ApiPort` (3900), `rpcPort` (3901), `adminPort` (3903),
  `region` ("garage"), `dataDir`, `metaDir` all removed. These had
  defaults that were the only values any consumer used. Now
  hardcoded as `let` bindings in `perInstance`.
- Kept: `address` (required, no default), `capacity` (meaningful
  for multi-node RF clamping), `dataDevice` (real feature: inline
  disko), `buckets.<name>.{enable,quotas,website}`, and
  `mounts.<name>.{bucket,mountPoint,readOnly}`.

**Layering:**

- Removed `options.cococoir.services = {};` from
  `modules/services/media-stack.nix` (empty submodule declaration
  that did nothing — each service module declares its own
  sub-attribute).
- `vpnConfigFile` stays in `qbittorrent.nix` (the user-facing
  surface for qbittorrent config) even though `media-stack.nix` is
  the only consumer. The layering note from the audit was
  retracted — the option is correctly owned by the qbittorrent
  module; the consumer doesn't need to know which sub-module reads
  it.

**`nix flake check` passes for both `path:.` and `path:tunnel`.**

#### Second-pass audit — dead code removed *(DONE this session)*

Going one step further. "Not rolled out to clients" means I can be
more aggressive: any option that no consumer actually uses is
maintenance liability, and the only consumer (amon-sul) is
explicitly opting in to the trimmed surface.

**`cococoir.users` (modules/core.nix):** removed. Only consumer
uses `cococoir.adminUsers`. The "non-admin user with no root
keys" shape was a future-proofing option with zero current
consumers. Re-introduce (or unify with `adminUsers`) when a
deployment needs it.

**`lib/garage-data-disko.nix`:** entire file deleted. The flake
didn't even export `cococoir.lib.mkGarageDataDisko` — references
in the docstrings were aspirational. 100% dead code. The `lib/`
directory is gone.

**`garage.buckets.<name>.{enable,quotas,website}`:** removed. The
submodule was three options deep with zero consumers. Now:
`buckets.<name> = { }` declares a bucket. `bucket-init.sh`
iterates over `builtins.attrNames me.buckets` instead of
`to_entries[] | select(.value.enable)`. The script dropped from
81 to 64 lines.

**`garage.dataDevice`:** removed. No consumer used the inline
disko path; amon-sul provisions the data drive via its own
disko.nix. The `disko = lib.mkIf (me.dataDevice != null) { ... }`
block is gone. The data drive must be provisioned out-of-band.

**Kept (with reason):**

- `cococoir.localNetworks` (default `192.168.0.0/16`) — only one
  consumer uses the default, but it's a real concern for
  non-192.168 networks. Not genericity.
- `tunnel.server.bindAddress` (default `0.0.0.0`) — same: real
  feature for multi-tenant VPSes.
- `cococoir.services.mautrix-gmessages.{settings,environmentFile}` —
  bridges are per-deployment config. The default `settings` is
  sensible but real consumers will override.
- `cococoir.services.qbittorrent.vpnConfigFile` — required
  qbittorrent dependency, provides a validation point.
- `mounts.<name>.readOnly` — real feature for read-only buckets.

`nix flake check` passes for both `path:.` and `path:tunnel`.

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
├── clan-services/
│   └── garage/
│       ├── default.nix          # the clan.service
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
│       ├── cryptpad.nix
│       ├── custom.nix
│       ├── jellyfin.nix
│       ├── jellyseerr.nix
│       ├── matrix.nix
│       ├── mautrix-gmessages.nix
│       ├── media-stack.nix
│       ├── nextcloud.nix
│       └── qbittorrent.nix
├── tunnel/                      # separate flake (phase 4)
│   ├── README.md
│   ├── terraform/
│   └── nix/
├── AGENTS.md
├── THE_GREAT_SIMPLIFICATION.md  # this file
└── LICENSE
```

## Open questions

1. **FUSE mount ownership** *(RESOLVED)*: garage owns mounts; service
   modules consume the derived path. `cococoir.storage.derived.mounts`
   is keyed by bucket name. See "Decisions logged this session" above.
2. **Tunnel project tech stack** *(RESOLVED)*: separate-flake
   monorepo. `tunnel/flake.nix` depends on `nixpkgs` only and exposes
   `nixosModules.{client,server}` + a dev shell. `tunnel/terraform/`
   is consumed directly (no flake). See `tunnel/README.md` for
   rationale and the consumer-side import pattern.
3. **`vaultwarden` / `forgejo` / `kavita` / `octoprint` deletion
   audit**: any of these have client demand? If yes, bring them
   back as proper S3-backed modules. If no, deletion is final.

## Session compact instructions

After a session break:
1. Read this file end-to-end.
2. Check `git log --oneline -10` for the latest commits.
3. Check `git status` for uncommitted work (Nextcloud, Cryptpad).
4. Continue from the "What's in progress" section.
