# Cococoir — Agent Context

## Overview

Cococoir is a **declarative self-hosting library** written as a NixOS module system. It provides a unified namespace (`config.cococoir`) for configuring users, reverse-proxy networking, VPN tunneling, and a growing catalog of web services.

It is consumed as a flake input by downstream deployment repos (e.g. `amon-sul`).

## Architecture

### Entry Point
`flake.nix` exports a single `nixosModules.default` that imports every module under `modules/`.

### Module Structure

| File | Purpose |
|------|---------|
| `modules/core.nix` | Defines `cococoir.domain`, `cococoir.adminUsers`, and `cococoir.users`. Handles user creation with SSH keys and wheel group membership. |
| `modules/base.nix` | Baseline system settings: fish shell, OpenSSH (no passwords), Denver timezone, `net.ipv4.ip_unprivileged_port_start = 80`, and flake-enabled Nix. |
| `modules/networking/caddy.nix` | Enables Caddy and opens UDP 443 for HTTP/3 (QUIC). |
| `modules/proxy/client.nix` | Configures **rathole client** — tunnels local ports (80, 443) to a remote VPS via the rathole protocol. Expects a `credentialsFile` with service tokens. |
| `modules/proxy/server.nix` | Configures **rathole server** — exposes public ports on a VPS and forwards them back to the client. |
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
| `media-stack.nix` | Transmission | `9091` | **VPN-confined** via `vpnNamespaces.wg`. Requires `vpnConfigFile`. |
| `media-stack.nix` | Radarr | `7878` | Shares `jellyfin` user/group. |
| `media-stack.nix` | Sonarr | `8989` | Shares `jellyfin` user/group. |
| `media-stack.nix` | Lidarr | `8686` | Shares `jellyfin` user/group. |
| `media-stack.nix` | Bazarr | `6767` | Shares `jellyfin` user/group. |
| `media-stack.nix` | Prowlarr | `9696` | — |
| `media-stack.nix` | FlareSolverr | `8191` | — |
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
