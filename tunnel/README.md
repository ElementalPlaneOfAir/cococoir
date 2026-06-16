# tunnel

A separate-flake project for the VPS + rathole + sops stack that fronts a
[cococoir](../) deployment. Lives in the same git repo as cococoir
("monorepo") but has its own `flake.nix`, its own `flake.lock`, and its
own dependency footprint (just `nixpkgs` — no `clan-core`).

## Why a separate flake

The tunnel stack has a different surface area than cococoir proper:

- It runs on a *VPS* (cloud-init-installed Hetzner box), not a NixOS
  home server. Different machine lifecycle, different secrets.
- It depends on `nixpkgs` only. No `clan-core`, no `vpn-confinement`.
- It ships infrastructure-as-code (OpenTofu) alongside NixOS modules,
  which is a different mental model than cococoir's "declarative
  self-hosting library" framing.

Mixing all of that into the cococoir flake would bloat its lockfile
and conflate two distinct concerns. Splitting them keeps each project
auditable in isolation.

## Layout

```
tunnel/
├── flake.nix              # nixpkgs-only flake; exposes nixosModules.{client,server}
├── nix/                   # NixOS modules
│   ├── client.nix         # rathole client (home server side)
│   └── server.nix         # rathole server (VPS side)
├── terraform/             # OpenTofu modules (no flake — consumed directly)
│   ├── modules/
│   │   ├── vps/           # Hetzner Cloud server + firewall
│   │   └── dns/           # Hetzner DNS zone + records
│   └── examples/basic/    # worked example
└── sops/
    └── machines/ionos-vps/key.json   # age public key for the VPS
```

## Consuming from a deployment repo

```nix
# flake.nix
inputs = {
  cococoir.url = "github:.../cococoir";
  tunnel.url = "path:./tunnel";   # if tunnel is a sub-folder of the same repo
  # or: tunnel.url = "github:.../cococoir?dir=tunnel";
};
```

```nix
# machine config
imports = [
  cococoir.nixosModules.default
  tunnel.nixosModules.client   # or .server, on the VPS
];
```

## Option namespace

The proxy modules expose options under `tunnel.{client,server}` (not
`cococoir.proxy.*` — the old namespace, removed when tunnel became its
own project).

## Quick start (terraform)

```bash
nix develop
cd terraform/examples/basic
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
export HCLOUD_TOKEN="..."
export HETZNER_DNS_API_TOKEN="..."
tofu init
tofu apply
```
