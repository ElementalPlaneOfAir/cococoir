# NixOS install

The native path: a Fortress machine is a NixOS machine. Each
machine is one file in your flake — storage, TLS, and DNS follow
the `baseDomain` automatically.

> **Note on the install script.** `install.sh` is for macOS and
> regular Linux, where it builds the demo container tier. On
> NixOS it stops with a pointer here and does not try to rebuild
> your system — NixOS belongs in `configuration.nix`, not in a
> piped shell script.

## Walk-through

### 1. Add the flake input

```nix
{
  inputs = {
    fortress.url = "github:ElementalPlaneOfAir/cococoir";
    inputs.fortress.inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

### 2. Import the module

```nix
{
  imports = [ inputs.fortress.nixosModules.default ];
}
```

### 3. Enable services and rebuild

Each service is one attrset: `enable`, `domain`, `public`.

```nix
fortress.baseDomain = "alice.example.com";
fortress.services.jellyfin = { enable = true; public = true; };
fortress.services.dex      = { enable = true; public = true; };
```

```bash
sudo nixos-rebuild switch --flake .#mybox
```

Each service gets its own Caddy vhost with automatic TLS. Enable a
service next to Dex and every user signs in with one account.

### 4. Storage

On real hardware Fortress wants a btrfs pool (`fortress.storage`):
per-service subvolumes, quotas, removable drives. In a container
(or any non-btrfs host) the `plain-dirs` backend is used and data
lives under directories instead.

### 5. Secrets

Operator-consumed secrets (OIDC provider settings, the WG keys)
are wired by sops-nix from the repo's `secrets/` folder. A
customer box decrypts them at activation; the keys never appear in
the repo plaintext.

## WireGuard tunnel + forwarder (v2)

The edge side is one Hetzner box, dialed by every customer
machine; the customer side is the `fortress-client` service — the
module wraps it, and the tunnel comes up at boot.

## FAQ

**Is Nix knowledge required?** No — the landing page above
inactive copy is honest: the module owns TLS, storage and DNS
wiring. You set a hostname and enable services.

**Can I run several machines?** Yes — one flake, N
`nixosConfigurations`, each importing the same module with its own
`baseDomain`; claim them under one account and they share a
remote-access surface.
