# Cococoir — Agent Context

## Overview

Cococoir is a **declarative self-hosting library** written as a NixOS module system on top of [flake-parts](https://flake.parts) and [clan-core](https://clan.lol). It provides a unified namespace (`config.cococoir`) for configuring users, reverse-proxy networking, a **distributed S3-compatible object store** (Garage), and a growing catalog of web services.

The VPS + rathole front-end is a **separate tech stack** living at `tunnel/` (its own flake, its own lockfile, only depends on `nixpkgs`). See `tunnel/README.md`.

It is consumed as a flake input by downstream deployment repos (e.g. `amon-sul`).

**License:** AGPL-3.0-or-later. See `LICENSE`. Every source file carries the matching SPDX header.

## Architecture

### Entry Point
`flake.nix` is a [flake-parts](https://flake.parts) flake. It exposes:

| Output | Purpose |
|--------|---------|
| `nixosModules.default` | Self-contained — imports every module under `modules/`. Use this as the base import for any machine. |
| `nixosModules.<name>` | Individual modules (`core`, `auth`, `base`, `storage`, `caddy`). For advanced use; most consumers just use `default`. |
| `modules.nixos.<name>` | **Per-service clan-core secret generators** (e.g. `storageVars`). Auto-imported from `flake-vars/`. Consumers add specific generators to the machines that need them. |

### Module Structure

| File | Purpose |
|------|---------|
| `modules/core.nix` | Defines `cococoir.domain`, `cococoir.adminUsers`, and `cococoir.users`. Handles user creation with SSH keys and wheel group membership. |
| `modules/auth.nix` | `cococoir.adminAuth` (basicauth via Caddy) and the `cococoir.lib.cococoir.withAuth` Caddy vhost helper. Used by services that don't have native OIDC. |
| `modules/auth/pocketid.nix` | **PocketID OIDC provider** — base-layer auth. Always-on, no `enable` toggle. Wraps nixpkgs `services.pocket-id` and adds a oneshot (`pocket-id-secret-init.service`) that generates `/var/lib/pocket-id/secrets.env` (ENCRYPTION_KEY + STATIC_API_KEY) on first boot. |
| `modules/base.nix` | Baseline system settings: fish shell, OpenSSH (no passwords), Denver timezone, `net.ipv4.ip_unprivileged_port_start = 80`, and flake-enabled Nix. |
| `modules/networking/caddy.nix` | Enables Caddy and opens UDP 443 for HTTP/3 (QUIC). |
| `modules/storage.nix` | Top-level `cococoir.storage.*` option tree: cluster layout, node identity, bucket definitions, FUSE mounts, and the derived public view. |
| `modules/storage/garage.nix` | `services.garage` config + secret-substitution `ExecStartPre` + `/etc/cococoir/garage.env` with run-time environment. |
| `modules/storage/bucket.nix` | `garage-bucket-init` oneshot: generates/reads the cluster-wide global key, iterates enabled buckets, applies per-bucket RF (with clamp warning), allows the global key per bucket, sets quotas and website hosting. |
| `modules/storage/fuse.nix` | Per-mount systemd service + mount unit pair using `geesefs` to expose S3 buckets as local filesystems. |
| `modules/services/custom.nix` | Generic reverse-proxy for arbitrary systemd services. Does **not** enable any upstream service; only creates Caddy virtual hosts based on `cococoir.services.custom.<name>` entries. |

## Base-Layer Auth (PocketID)

PocketID is the OIDC provider for the entire cococoir stack. It is **always-on base infrastructure** (like `cococoir/garage`) — never opt-in, never behind a `services.pocket-id.enable` toggle. The user configures it under `cococoir.auth.pocketid.*`:

```nix
cococoir.auth.pocketid = {
  domain = "auth.example.com";   # required
  public = true;                 # default true; Caddy reverse-proxies
  signupMode = "disabled";       # disabled / withToken / open
};
```

**Why always-on**: every cococoir service that supports OIDC (Jellyfin, Jellyseerr, autobrr, Synapse, Nextcloud) and every service that uses Caddy forward_auth (qBittorrent) eventually needs an OIDC provider. Shipping one is a precondition for the unified auth story.

**Secret model**: PocketID is single-instance (not a cluster), so the secrets (`ENCRYPTION_KEY`, `STATIC_API_KEY`) are stored plaintext at `/var/lib/pocket-id/secrets.env` (mode 0640, owned by `pocket-id:pocket-id`). Disk encryption (LUKS) protects them at rest — same model PocketID itself uses in its docker-compose examples. `pocket-id-secret-init.service` generates this file idempotently on first boot.

**Per-service OIDC wiring (Phase 2)**: each service module will expose `cococoir.services.<name>.oidc = { enable = true; }`. A `pocket-id-oidc-init.service` oneshot (deferred) uses the STATIC_API_KEY to call PocketID's API and create an OIDC client per service, writing client_id + client_secret to per-service runtime files that the service modules consume.

**Caddy forward_auth for non-native services (Phase 2)**: qBittorrent and (optionally) CryptPad will be gated by Caddy's `caddy-security` plugin, using PocketID as the OIDC provider. This requires a custom Caddy build (one-time).

### Service Modules

Every service under `modules/services/` follows a **consistent, opinionated pattern**. Service modules are intentionally minimal — deployers should not have to learn the upstream NixOS module's option surface to get a working service.

1. **Options** under `cococoir.services.<name>`. The full set, no more:

   | Option | Type | Required? | Purpose |
   |--------|------|-----------|---------|
   | `enable` | bool | yes | Opt-in toggle. |
   | `domain` | str | yes | External FQDN for the Caddy vhost. |
   | `public` | bool | yes | `true` → Caddy reverse-proxies to the service. `false` → Caddy returns `403`. |
   | `bucket` | str | only for S3-using services | Name of the Garage bucket this service reads from or writes to. |

   That's it. No `port`, `signupsAllowed`, `openFirewall`, `secretFile`, or VPN knob — the module picks sensible defaults, binds to `127.0.0.1`, and delegates to clan-core vars for secrets.

2. **Config**:
   - Enables the upstream NixOS service (`services.<name>.enable = true`)
   - Binds to `127.0.0.1:<hardcoded port>`
   - For S3-using services, wires the native S3 backend (or, where the upstream lacks one, a FUSE-mounted `cococoir.storage.mounts.<name>` mountpoint on the bucket).
   - Registers a Caddy virtual host:
     ```nix
     services.caddy.virtualHosts."${cfg.domain}".extraConfig =
       if cfg.public then ''reverse_proxy localhost:<port>'' else ''respond "Forbidden" 403'';
     ```

| Service File | Service | Local Port | Notes |
|--------------|---------|------------|-------|
| `jellyfin.nix` | Jellyfin | `8096` | Creates `jellyfin` system user with `render`/`video` groups. Library lives on a FUSE-mounted Garage bucket. |
| `jellyseerr.nix` | Jellyseerr (seerr) | `5055` | Unified movie/TV request UI. Points at Jellyfin + qBittorrent. Delegates to nixpkgs `services.seerr`. |
| `qbittorrent.nix` | qBittorrent | `8080` (WebUI) | **VPN-confined** via `vpnNamespaces.wg`. Downloads land on a FUSE-mounted Garage bucket. Pairs with autobrr. |
| `autobrr.nix` | autobrr | `7474` | Release automation. Hands matched releases to qBittorrent. |
| `matrix.nix` | Matrix (Synapse) | `6167` | Also serves `.well-known/matrix/*` on the base domain. |
| `mautrix-gmessages.nix` | mautrix-gmessages | `29336` | Matrix-Google Messages bridge. No Caddy vhost (appservice). Requires PostgreSQL. |
| `cryptpad.nix` | CryptPad | `9123` | `dataPath` lives on a FUSE-mounted Garage bucket. |
| `custom.nix` | *(any)* | *(user-defined)* | Generic reverse-proxy for arbitrary systemd services. See [Live TV / Sports Streaming](#live-tv--sports-streaming) for a worked example (Threadfin + Jellyfin Live TV). |

## Adding a New First-Party Service

For services that have a built-in NixOS module, create a dedicated wrapper in `modules/services/<name>.nix` following the pattern above. The four-option contract (`enable`, `domain`, `public`, `bucket`-if-S3-using) is the entire surface — don't expose more options than that, even if the upstream module does.

## Adding a Custom / Third-Party Service

For services **without** an upstream NixOS module (e.g. Threadfin), use the generic `custom` mechanism. This adds a Caddy vhost only — the upstream service (package, systemd unit, Nix module) is defined in the deployment repo, not cococoir.

```nix
# In the downstream repo (e.g. amon-sul/config.nix)
cococoir.services.custom.my-app = {
  enable = true;
  domain = "misc.interdim.net";
  port = 8080;                       # only option not in the standard 4
  public = true;
};
```

## Storage

The `cococoir.storage.*` option tree provisions a [Garage](https://garagehq.deuxfleurs.fr/) cluster — a distributed, S3-compatible object store. The design is built around three real-world product constraints:

1. **Seamless 1→3 node upgrade.** A single-machine deployment must work; adding nodes must not require a config rewrite.
2. **Per-bucket replication factor (RF).** Media is RF=1 (re-downloadable). Documents/email/personal data is RF=3 (loss unacceptable).
3. **One cluster, one key.** A single global access key per cluster is simpler than per-bucket keys and the derived view surfaces it for native-S3 apps.

### Cluster Layout

```nix
cococoir.storage = {
  enable = true;
  cluster = {
    clusterId   = "interdim";          # only used for human-readable logging
    rpcSecretFile = null;              # defaults to clan-core secret generator path
    s3ApiPort   = 3900;
    rpcPort     = 3901;
    adminPort   = 3903;
    region      = "garage";
    bootstrapPeers = [                 # manual, per-machine: list everyone EXCEPT this node
      "10.0.0.3:3901"
      "10.0.0.4:3901"
    ];
    layout.zones = [
      { id = "z1"; capacity = "1T"; }   # used for RF clamping and capacity calculations
      { id = "z2"; capacity = "1T"; }
      { id = "z3"; capacity = "1T"; }
    ];
  };
  node = {
    id       = "node-1";                 # consumer sets this explicitly
    address  = "10.0.0.2:3901";          # this node's RPC public address
    zone     = "z1";                     # which layout.zone this node belongs to
    dataDir  = "/var/lib/cococoir/garage/data";
    metaDir  = "/var/lib/cococoir/garage/meta";
    capacity = "1T";                     # contributes to zone capacity
  };
  buckets.media    = { replicationFactor = 1; };
  buckets.documents = { replicationFactor = 3; };

  mounts.media = { bucket = "media"; mountPoint = "/media/entertain"; readOnly = false; };
};
```

### RF Clamping

Requested RF is clamped to the number of layout zones with non-zero capacity:

```nix
clampedRF = if rf <= numZonesWithCapacity then rf
            else if numZonesWithCapacity == 0 then 1
            else numZonesWithCapacity;
```

A NixOS assertion fires at evaluation time if `clampedRF != rf` — this is **intentional** and matches the "production safety: impossible layouts are caught at `nix flake check` time" stance. The 1→3 node upgrade story therefore requires:

1. Add a second `layout.zones` entry and a second node.
2. Update the cluster's `bootstrapPeers` to include the new node.
3. Reduce per-bucket `replicationFactor` (or accept the assertion, then reduce RF, then re-evaluate).

A `garage-bucket-init` oneshot also logs a `[WARN]` line on every boot if the deployed cluster still has fewer zones than the bucket requested (e.g. during a rolling upgrade).

### Topologies

| Topology | `layout.zones` | Use case | Notes |
|----------|----------------|----------|-------|
| 1-node, 1-zone | `[{ id = "z1"; capacity = "1T"; }]` | Initial deployment, dev, "just want to try it" | All buckets must be `replicationFactor = 1`. Higher RF fails the eval-time assertion. |
| 2-node, 2-zone | `[{ id = "z1"; ... } { id = "z2"; ... }]` | Single-disk backup pair | RF=2 works; RF=3 fails. |
| 3-node, 3-zone | `[{ id = "z1"; ... } { id = "z2"; ... } { id = "z3"; ... }]` | Default business-plan deployment | RF=1, RF=2, RF=3 all work. |
| 5-10 nodes, 3+ zones | `[{ id = "z1"; ... } { id = "z2"; ... } { id = "z3"; ... }]` | Larger cluster, asymmetric | Multiple nodes per zone — capacity aggregates. |

### FUSE Mounts

`cococoir.storage.mounts.<name>` exposes an S3 bucket as a local filesystem via `geesefs`. Each mount becomes a systemd service + mount unit pair. Use this for any service that needs a local filesystem path (qBittorrent downloads, Jellyfin libraries, etc.) and that doesn't care about the S3 semantics underneath.

```nix
cococoir.storage.mounts.media = {
  bucket     = "media";
  mountPoint = "/media/entertain";
  readOnly   = false;          # default: rw
  # extraOptions = [ "noxattr" ];  # for filesystems that don't support xattr
};
```

### Derived Public View

For native-S3 clients, the resolved (post-clamp) state is exposed read-only:

```nix
cococoir.storage.derived.buckets.<name> = {
  name;                          # "media"
  endpoint;                      # "http://127.0.0.1:3900"
  region;                        # "garage"
  accessKeyId;                   # "GK..."
  secretAccessKeyFile;           # /var/lib/cococoir/garage/.global-key
  replicationFactor;             # 1  (clamped)
  intendedReplicationFactor;     # 1  (requested)
};

cococoir.storage.derived.gatewayAddress;  # "127.0.0.1:3900"
```

### Clan Secret Generators

The storage module requires a per-cluster RPC secret, generated once on the first machine and shared across all cluster nodes. This is provided by `cococoir.modules.nixos.storageVars`:

```nix
# In a machine config (e.g. amon-sul)
imports = [
  cococoir.nixosModules.default
  cococoir.modules.nixos.storageVars
];
```

`storageVars` defines two clan-core generators:

| Generator | Scope | Purpose |
|-----------|-------|---------|
| `storage-rpc-secret` | `share = true` (shared) | 32-byte hex, written to `vars/shared/storage-rpc-secret/rpc-secret`. Used as the Garage cluster RPC secret. |
| `storage-global-key` | placeholder | Reserved for the cluster-wide S3 access key generated at first boot by `garage-bucket-init`. |

The first machine to evaluate gets a real secret; the rest read the same file. The default `cococoir.storage.cluster.rpcSecretFile` resolves to `config.clan.core.vars.generators.storage-rpc-secret.files.rpc-secret.path`, so no manual path wiring is needed.

### Per-Service Vars Pattern

Any cococoir service that needs secrets ships its own clan-core generator module. Convention:

- One file per service: `flake-vars/<service>-vars.nix`
- Each file exposes `flake.modules.nixos.<service>Vars` via `imports = []` on the flake-parts root.
- Generators live in `clan.core.vars.generators.<name>` (referenced from the corresponding `modules/services/<name>.nix`).
- Consumers add `cococoir.modules.nixos.<service>Vars` to **only the machines that need it**.

Example (`flake-vars/storage-vars.nix`):

```nix
{
  flake.modules.nixos.storageVars = { ... }: {
    clan.core.vars.generators.storage-rpc-secret = {
      share = true;
      files.rpc-secret = {
        secret = false;
        owner = "root";
        group = "root";
        mode = "0400";
        source.passFile = "/dev/urandom";
        source.script = ''
          tr -dc 'a-f0-9' < /dev/urandom | head -c 64
        '';
      };
    };
  };
}
```

## Live TV / Sports Streaming

The *arr stack → Jellyfin pipeline handles movies and series well, but live sports isn't a "grab a release" problem — it's a "subscribe to a broadcast stream" problem. The equivalent pipeline is **Threadfin** (an M3U proxy) feeding **Jellyfin's built-in Live TV / DVR** so the same UI your dad already uses becomes a grid guide for live games.

### Architecture

```
[upstream M3U + XMLTV]
      │  free aggregators, IPTV provider, HDHomeRun, etc.
      ▼
[Threadfin on :34400]   ── filter, dedupe, map EPG, group by league
      │
      ├── /m3u   ──▶  Jellyfin Live TV tuner
      └── /xmltv ──▶  Jellyfin Live TV EPG
                        │
                        ▼
                 [Caddy → tv.<domain> or jellyfin.<domain>]
                        │
                        ▼
                 Apple TV / web / phone (one app, one guide)
```

Typical end-to-end delay is **5–30 seconds** (one HLS segment + origin latency) — well under the 1-minute mark. The *arr → Jellyfin stack is slower because of release-group re-encoding; this path is HLS passthrough.

### Cococoir wiring

Threadfin isn't in nixpkgs, so it follows the **custom service** pattern: its NixOS module and systemd service are defined in the deployment repo, and Cococoir just exposes the admin UI through Caddy.

```nix
# In the downstream deployment repo (e.g. amon-sul/configuration.nix)
cococoir.services.custom.threadfin = {
  enable = true;
  domain = "tv-helper.interdim.net";   # admin UI for curating the channel list
  port = 34400;                         # Threadfin's default
  public = false;                       # admin-only; Jellyfin hits 127.0.0.1:34400 directly
};

cococoir.services.jellyfin = {
  enable = true;
  domain = "jellyfin.interdim.net";
  public = true;
  # Jellyfin's Live TV section is configured at runtime in the admin UI:
  #   Tuner type:  M3U Tuner
  #   File/URL:    http://127.0.0.1:34400/m3u/threadfin
  #   EPG:         http://127.0.0.1:34400/xmltv/threadfin
};
```

Threadfin's Nix module (build from source, systemd unit, persistent `/var/lib/cococoir/threadfin` data dir) lives in the deployment repo, alongside any other bespoke services. **No `flake-vars/` generator is needed** — M3U sources and EPG URLs aren't secrets, they're config that goes in Threadfin's own settings file.

### Maintenance

Free M3U aggregators are volatile. Budget ~30 minutes/month to swap dead sources. Threadfin's filter groups and channel mapping persist across upstream changes, so the curation work compounds over time.

Alternatives if Threadfin is stale: **xTeVe** (abandoned but still works), **Dispatcharr** (newer fork).

## Infrastructure Provisioning

VPS and DNS provisioning lives in the `tunnel/` sub-project (see
`tunnel/README.md`). Everything uses **Hetzner** (Cloud + DNS) so users
only need a single account and API token.

### Dev Shell

`flake.nix` exposes a devShell with Terraform and Go available:

```bash
nix develop
```

## Networking Model

- **Caddy** runs on the home server (`amon-sul`) and terminates TLS.
- **Rathole client** forwards ports 80/443 from the home server to the VPS.
- **Rathole server** on the VPS exposes those ports publicly.
- Services that should not be public still get a Caddy vhost but return `403`.
- VPN-confined services (Transmission) live in a WireGuard namespace (`vpnNamespaces.wg`) and are reverse-proxied via the namespace gateway IP (`192.168.15.1`).
