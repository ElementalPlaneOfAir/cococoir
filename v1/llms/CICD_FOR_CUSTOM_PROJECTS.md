# CICD for Custom Projects on NixOS/Clan Homelab

## Context

The current setup is a NixOS homelab managed via [Clan](https://clan.lol/) with the following properties:

- **Two machines**: `amon-sul` (beefy home server) and `ionos-vps` (public-facing VPS)
- **Networking**: Rathole tunnel from VPS → home server. Caddy terminates TLS on the home server.
- **DNS**: `*.interdim.net` routes through the VPS tunnel to Caddy on `amon-sul`
- **Service model**: All services declared in a single flake (`cococoir`) using the dendritic pattern
- **Deployment flow**: `nix flake update → git push → clan machines update amon-sul`

Existing services (Jellyfin, CryptPad, Transmission) are all declared natively in NixOS modules within the main repo.

## The Problem

We want to support **ad-hoc web projects** that can be developed, built, and deployed independently, without the friction of the current monolithic workflow.

### What "PaaS-like" Means Here

- Push to `main` → automatic build → automatic deploy → live on a subdomain
- Web dashboard showing build status, logs, history (green/red)
- Per-project isolation: one project's compilation error must never block other projects or system updates
- Native Nix derivations, not Docker/OCI containers

### What the Current Setup Cannot Do Well

1. **Lockfile pollution**: Pinning every project in `cococoir`'s `flake.nix` creates endless `flake.lock` churn
2. **Fragile deploys**: A single bad project input prevents the entire system from evaluating or deploying
3. **Slow feedback loop**: Every change requires a full `clan machines update`, even for a typo fix in one app
4. **No dashboard**: No web UI to see which apps built, which failed, and why

## Requirements

1. **Nix-native**: Projects export derivations (or NixOS modules), not Docker images
2. **GitOps**: Push to a repo triggers build and deploy automatically
3. **Per-project builds**: Each project evaluates and builds independently
4. **Atomic activation**: Only swap to the new version if the build succeeds; rollback on failure
5. **No repo pollution**: The main `cococoir` flake should not need to know about every side project
6. **Reverse proxy integration**: New projects should automatically appear in Caddy with the correct domain
7. **Dashboard**: Web UI for build logs, status, and history
8. **Beefy-server friendly**: Builds happen on the home server, not on external CI

## Solutions Explored

### 1. Monorepo Flake Inputs (Pinning Projects in `cococoir`)

**How it works**: Each project is a `flake.nix` input in `cococoir`. A CI job updates the lockfile and runs `clan machines update`.

**Pros**:
- Fully declarative
- Single atomic system closure
- Easy rollback via `nixos-rebuild switch --rollback`

**Cons**:
- Lockfile pollution: every project push generates a `cococoir` commit
- Fragile: one bad input breaks the entire system evaluation
- Slow: every deploy is a full NixOS rebuild
- Bad isolation: projects are not independent

**Verdict**: This is the status quo and it does not scale to ad-hoc projects.

### 2. Podman Quadlets + Nixpacks

**How it works**: Use `nixpacks` to build OCI images, drop Podman Quadlet files into `/etc/containers/systemd/`, and reload.

**Pros**:
- Familiar if coming from PaaS tools
- Good isolation between apps

**Cons**:
- Requires Docker/OCI, which is unwanted
- Loses the benefits of native Nix derivations (closure sharing, GC, purity)
- Still needs Caddy coordination

**Verdict**: Rejected. The user explicitly does not want containers.

### 3. Arion

**How it works**: Nix-native Docker Compose. Projects expose `arion` compositions.

**Pros**:
- Nix-native
- Good for multi-container project definitions

**Cons**:
- Still Docker under the hood
- More suited for multi-service projects than simple web apps
- Doesn't solve the push-to-deploy or dashboard problems

**Verdict**: Not a fit.

### 4. Nomad

**How it works**: Hashicorp Nomad schedules containers or native binaries on the server.

**Pros**:
- Has a UI
- Supports multiple job types

**Cons**:
- Heavyweight for a single home server
- Native binary support is secondary to containers
- Requires significant bridging to Caddy and the existing NixOS setup

**Verdict**: Overkill and not Nix-native enough.

### 5. Coolify / Dokku

**How it works**: Self-hosted PaaS that accepts git pushes, builds with nixpacks/Docker, and serves.

**Pros**:
- Real PaaS experience with dashboard
- Supports nixpacks

**Cons**:
- Not Nix-native: builds Docker images, not Nix derivations
- Introduces a second reverse proxy (Traefik/Caddy inside Coolify)
- Disconnects app lifecycle from NixOS/Clan

**Verdict**: Wrong abstraction layer.

### 6. Forgejo + Forgejo Actions + Clan

**How it works**: Self-hosted Git forge with CI runners. On push, CI builds the project, updates `cococoir`'s lockfile, and runs `clan machines update`.

**Pros**:
- Gives the dashboard and build logs
- CI runs on the beefy home server
- Familiar GitHub Actions syntax

**Cons**:
- Still pollutes the `cococoir` repo with lockfile commits
- Still fragile: a build failure in CI means the system update never happens (or worse, the lockfile is updated but the build is bad)
- Does not solve the "one bad project blocks everything" problem

**Verdict**: Better UX, but same fundamental architecture problems.

### 7. buildbot-nix

**How it works**: Nix-native CI that listens to Git webhooks, builds flakes, and has a web dashboard.

**Pros**:
- Deep Nix integration
- Understands flakes natively
- Good for multi-repo build orchestration

**Cons**:
- The "deploy" step is still up to the user
- No built-in concept of "activate this derivation as a systemd service on this host"

**Verdict**: Excellent for building, but needs a custom activation layer.

### 8. Ultra-Minimal Webhook Receiver

**How it works**: A small HTTP server on `amon-sul` receives Git webhooks and runs a script to build and activate.

**Pros**:
- Extremely simple
- No dependencies beyond NixOS

**Cons**:
- No dashboard, no build history, no logs UI
- Re-inventing a lot of what Forgejo/buildbot already do well

**Verdict**: Too primitive for the desired UX.

### 9. Custom Deployment Agent (The Most Promising)

**How it works**: A lightweight agent running on `amon-sul` watches each project's Git endpoint independently. On change:

1. Clone/fetch the repo
2. `nix build .#packages.x86_64-linux.default`
3. If success: atomically swap a symlink (`current → builds/<hash>`), restart a templated systemd unit, regenerate Caddy config, reload Caddy
4. If failure: leave the old symlink untouched; log the error

**Directory layout**:

```
/var/lib/cococoir-apps/
├── myapp/
│   ├── repo/                # git clone
│   ├── current → builds/abc123/
│   ├── builds/
│   │   └── abc123/          # nix build result
│   ├── myapp.sock           # unix domain socket
│   └── caddy.conf           # generated vhost snippet
└── otherapp/
    └── ...
```

**Systemd unit template** (`cococoir-app@.service`):

```ini
[Unit]
Description=Cococoir App %i
After=network.target

[Service]
Type=notify
ExecStart=/var/lib/cococoir-apps/%i/current/bin/%i
Restart=always
WorkingDirectory=/var/lib/cococoir-apps/%i
Environment="SOCKET_PATH=/var/lib/cococoir-apps/%i/%i.sock"

[Install]
WantedBy=multi-user.target
```

**Caddy integration**: Main Caddy config imports all app snippets:

```caddy
import /var/lib/cococoir-apps/*/caddy.conf
```

**Pros**:
- No lockfile pollution in `cococoir`
- Per-project isolation: one bad build only affects that app
- Atomic activation via symlink swap
- Automatic rollback on failure
- Fully Nix-native

**Cons**:
- Custom code needed for the watcher (likely ~200 lines)
- No built-in dashboard (though systemd + Caddy logs exist)
- Not an off-the-shelf product

**Verdict**: This is the closest technical fit, but it requires building and maintaining a custom tool.

## The Ideal Solution (A Proposal)

What does not currently exist is a **Nix-native, Clan-integrated application deployment layer** that sits alongside the system deployment layer.

Imagine a tool (or a Clan feature) called something like `clan apps` or `clan services` with the following properties:

### System-Level (Owned by `cococoir`)

The main Clan flake only declares:

- The app runtime daemon (watcher/builder)
- Caddy (with a wildcard import for app vhosts)
- The base infrastructure (DNS, networking, storage)

It never declares individual apps.

### App-Level (Owned by Each Project)

Each project is a standalone flake with a standard output schema:

```nix
{
  outputs = { self, nixpkgs }: {
    # The executable that will run as a service
    packages.x86_64-linux.default = ...;

    # Optional: metadata for the deployment agent
    cococoirApp = {
      domain = "myapp.interdim.net";
      port = 8080;  # or use Unix socket
      env = { FOO = "bar"; };
    };
  };
}
```

### The Agent

A daemon (perhaps part of Clan, perhaps separate) that:

1. Reads a list of watched repos from a config file (`/etc/cococoir/apps.toml`)
2. Polls (or receives webhooks from) those repos
3. Runs `nix build` for each project in isolation
4. Manages the symlink + systemd lifecycle
5. Generates reverse proxy config (Caddy/NGINX)
6. Exposes a small web UI or API for status/logs

### Why This Should Be a Clan Feature

Clan already solves the hardest parts of NixOS fleet management:

- Secret management
- Remote deployment
- Inventory/discovery
- Mesh networking

What is missing is a layer for **application lifecycle management** that is:

- Independent of the system lifecycle
- GitOps-driven
- Observable

A `clan apps` subcommand could fill this gap without compromising the purity of `clan machines`.

## Open Questions

1. **Should builds be ephemeral or cached?**
   - If cached: the Nix store already handles this
   - If ephemeral: build, activate, then GC the old closure later

2. **How should domains be managed?**
   - Automatic subdomains based on repo name? (`<repo>.interdim.net`)
   - Explicit declaration in a project metadata file?
   - Central registry in the agent config?

3. **What is the rollback UX?**
   - The symlink model gives instant rollback per app
   - Should there be a `clan apps rollback myapp` command?

4. **Dashboard scope**
   - Is a minimal read-only view of systemd + build logs enough?
   - Or should it integrate with a full forge like Forgejo for the source-level view?

5. **Multi-machine**
   - If the user eventually has multiple home servers, should the agent schedule apps across them?
   - This starts to look like a lightweight Nomad, but Nix-native

## Related Work

- [Cachix Deploy](https://deploy.cachix.org/): Activates store paths, but assumes pre-built closures
- [deploy-rs](https://github.com/serokell/deploy-rs): Remote NixOS activation, not app-level
- [NixOS containers](https://nixos.org/manual/nixos/stable/#ch-containers): Independent evaluation, but still host-declared
- [buildbot-nix](https://github.com/Mic92/buildbot-nix): Excellent CI, no deploy layer
- [hercules-ci-effects](https://docs.hercules-ci.com/hercules-ci-effects/): GitOps NixOS deployment, but system-level only
- [arion](https://github.com/hercules-ci/arion): Docker Compose in Nix, not what we want here

## Recommendation

The custom agent approach is technically viable and could be built today. However, it would be a bespoke tool that the user maintains alone.

A better long-term outcome is to **engage with the Clan project** to explore whether an application deployment layer fits their roadmap. Clan is already solving adjacent problems (secrets, mesh networking, remote execution) and has the right philosophy (Nix-native, declarative, reproducible). Adding a per-app GitOps layer would make Clan a complete solution for both "infrastructure" and "workloads" on NixOS homelabs.

The pitch to Clan would be:

> "You have `clan machines` for deploying NixOS systems. What about `clan apps` for deploying Nix derivations as independently managed, GitOps-driven services?"
