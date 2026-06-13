# Cococoir — Agent Context

## Overview

Cococoir is a **declarative self-hosting library** written as a NixOS module system on top of [flake-parts](https://flake.parts) and [clan-core](https://clan.lol). It provides a unified namespace (`config.cococoir`) for configuring users, reverse-proxy networking, VPN tunneling, a **distributed S3-compatible object store** (Garage), and a growing catalog of web services.

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
| `modules/auth.nix` | Re-exports clan-core secret generators that cococoir services need (e.g. Vaultwarden admin token, autobrr session). |
| `modules/base.nix` | Baseline system settings: fish shell, OpenSSH (no passwords), Denver timezone, `net.ipv4.ip_unprivileged_port_start = 80`, and flake-enabled Nix. |
| `modules/networking/caddy.nix` | Enables Caddy and opens UDP 443 for HTTP/3 (QUIC). |
| `modules/proxy/client.nix` | Configures **rathole client** — tunnels local ports (80, 443) to a remote VPS via the rathole protocol. Expects a `credentialsFile` with service tokens. |
| `modules/proxy/server.nix` | Configures **rathole server** — exposes public ports on a VPS and forwards them back to the client. |
| `modules/storage.nix` | Top-level `cococoir.storage.*` option tree: cluster layout, node identity, bucket definitions, FUSE mounts, and the derived public view. |
| `modules/storage/garage.nix` | `services.garage` config + secret-substitution `ExecStartPre` + `/etc/cococoir/garage.env` with run-time environment. |
| `modules/storage/bucket.nix` | `garage-bucket-init` oneshot: generates/reads the cluster-wide global key, iterates enabled buckets, applies per-bucket RF (with clamp warning), allows the global key per bucket, sets quotas and website hosting. |
| `modules/storage/fuse.nix` | Per-mount systemd service + mount unit pair using `geesefs` to expose S3 buckets as local filesystems. |
| `modules/services/custom.nix` | Generic reverse-proxy for arbitrary systemd services. Does **not** enable any upstream service; only creates Caddy virtual hosts based on `cococoir.services.custom.<name>` entries. |

### Service Modules

Every service under `modules/services/` follows a **consistent pattern**:

1. **Options** under `cococoir.services.<name>`:
   - `enable` — `mkEnableOption`
   - `domain` — the external FQDN (e.g. `jellyfin.interdim.net`)
   - `public` — if `true`, Caddy reverse-proxies to the service; if `false`, returns `403 Forbidden`

2. **Config**:
   - Enables the upstream NixOS service (`services.<name>.enable = true`)
   - Binds to `127.0.0.1:<port>` (or a VPN namespace address)
   - Registers a Caddy virtual host:
     ```nix
     services.caddy.virtualHosts."${cfg.domain}".extraConfig =
       if cfg.public then ''reverse_proxy localhost:<port>'' else ''respond "Forbidden" 403'';
     ```

| Service File | Service | Local Port | Notes |
|--------------|---------|------------|-------|
| `jellyfin.nix` | Jellyfin | `8096` | Creates `jellyfin` system user with `render`/`video` groups. |
| `vaultwarden.nix` | Vaultwarden | `8222` | Has `signupsAllowed` option. |
| `forgejo.nix` | Forgejo | `3121` | — |
| `matrix.nix` | Matrix (Synapse) | `6167` | Also serves `.well-known/matrix/*` on the base domain. |
| `mautrix-gmessages.nix` | mautrix-gmessages | `29336` | Matrix-Google Messages bridge. No Caddy vhost (appservice). Requires PostgreSQL. |
| `cryptpad.nix` | CryptPad | `9123` | — |
| `qbittorrent.nix` | qBittorrent | `8080` (WebUI) | **VPN-confined** via `vpnNamespaces.wg`. Requires `vpnConfigFile`. Pairs with autobrr. |
| `autobrr.nix` | autobrr | `7474` | Release automation. Hands matched releases to qBittorrent. Requires `secretFile`. |
| `jellyseerr.nix` | Jellyseerr (seerr) | `5055` | Unified movie/TV request UI. Points at Jellyfin + qBittorrent. |
| `octoprint.nix` | OctoPrint | `5321` | — |
| `kavita.nix` | Kavita | `5001` | — |
| `custom.nix` | *(any)* | *(user-defined)* | Generic reverse-proxy for arbitrary systemd services. |

## Adding a New First-Party Service

For services that have a built-in NixOS module (Jellyfin, Vaultwarden, etc.), create a dedicated wrapper in `modules/services/<name>.nix` following the established pattern.

## Adding a Custom / Third-Party Service

For services **without** an upstream NixOS module (e.g. a bespoke Go server), use the generic `custom` mechanism so Cococoir stays decoupled from project-specific code:

```nix
# In the downstream repo (e.g. amon-sul/config.nix)
cococoir.services.custom.my-app = {
  enable = true;
  domain = "misc.interdim.net";
  port = 8080;
  public = true;
};
```

The upstream systemd service, package, and module are defined **in the project's own flake** and imported directly by the deployment repo. Cococoir only handles the Caddy reverse-proxy virtual host.

### Minimal Service Template (for Cococoir wrapper modules)

```nix
{ config, lib, ... }:
let
  cfg = config.cococoir.services.<name>;
in
{
  options.cococoir.services.<name> = {
    enable = lib.mkEnableOption "<description>";
    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for <name>.";
    };
    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to <name>.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.<upstream> = {
      enable = true;
      # bind to localhost
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:<port>''
      else ''respond "Forbidden" 403'';
  };
}
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

### Adding a New First-Party Service

For services that have a built-in NixOS module (Jellyfin, Vaultwarden, etc.), create a dedicated wrapper in `modules/services/<name>.nix` following the established pattern. If the service needs secrets, also create `flake-vars/<service>-vars.nix` declaring `flake.modules.nixos.<service>Vars`.

## CLI Tool

The `cli/` directory contains a Go-based CLI application for managing Cococoir deployments.

### Commands

| Command | Description |
|---------|-------------|
| `cococoir init [dir]` | Interactive wizard to scaffold a new project |
| `cococoir add service` | Add a new service to an existing project |
| `cococoir status` | Show deployment status (placeholder) |
| `cococoir version` | Print version info |

### Building

```bash
nix build .#default          # Build the CLI
nix run .#default -- init    # Run directly
nix develop                  # Enter dev shell with Go tooling
```

### Implementation

- **Cobra** for command structure
- **Huh** (Charm) for interactive forms
- **Lipgloss** for terminal styling

## Infrastructure Provisioning

The `terraform/` directory contains reusable modules for provisioning the VPS and DNS records needed for a Cococoir deployment. Everything uses **Hetzner** (Cloud + DNS) so users only need a single account and API token.

| Module | Provider | Purpose |
|--------|----------|---------|
| `terraform/modules/vps` | Hetzner Cloud | Server, firewall (22/80/443/2333), SSH key |
| `terraform/modules/dns` | Hetzner DNS | Zone + A/AAAA records |

The `terraform/examples/basic/` directory shows how to wire both modules together. It creates a server and points a domain (and wildcard) at it.

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
