# Cococoir remote infra

Provisioning for the IPv6 edge demo — the "global IP box" from
`writing/human/architecture_of_ipv6.md`, plus the DNS that fronts it.
Everything here is **OpenTofu** (single `hcloud` provider, single
HCLOUD_TOKEN, DNS managed through the GA Hetzner DNS API) so the whole
deployment can be reviewed and modified in one place.

## Layout

```
remote-infra/
├── tofu/                    # OpenTofu: the source of truth
│   ├── main.tf              # server, firewall, ssh key, address derivation
│   ├── dns.tf               # interdim.net zone + records
│   ├── render.tf            # renders the customer (NixOS) config from template
│   ├── templates/           # example123.nix template
│   ├── versions.tf          # hcloud + local providers
│   └── terraform.tfvars.example
├── nix/                     # RENDERED NixOS configs (checked in, public values)
│   └── example123.nix       #   overwritten by tofu apply (customer box only)
├── system-manager/          # edge box config (stock Debian, no NixOS)
│   └── edge.nix             #   applied via system-manager switch
├── scripts/
│   └── provision-edge.sh    # secretspec resolve -> tofu -> nix install -> system-manager -> wire WG
└── .secrets/                # gitignored: secretspec provisioning store (token, admin key)
```

## Why this shape

- **No first-party NixOS image on Hetzner** (confirmed via changelog
  2026-08). The edge box boots a stock `debian-12` image and
  **system-manager** applies the cococoir config on top (systemd
  services, packages, `/etc` files) without taking over the OS. This
  sidesteps the disko/fstab/NIC boot failures that plagued the old
  NixOS edge. Customer boxes stay full NixOS — that's the product.
- **One source of truth for addressing.** The edge IPv4, the routed
  `/64`, and the customer `/128` are derived once in `tofu/main.tf`
  (`cidrhost`) and flow into the DNS records, the customer NixOS
  config, and the provision script's WireGuard config. Change a
  variable → re-apply → everything stays consistent.
- **Secrets never in git.** The Hetzner token + generated admin key
  live in the secretspec provisioning store at `.secrets/`
  (gitignored), resolved via `nix run .#secretspec -- export -P
  provisioning -S <scope>`. WG identities are owned at runtime by the
  edge binary — nothing here provisions key material. Only IPs land in
  the rendered (checked-in) configs.

## The IPv6 model being provisioned

```
cellular (IPv6) ──*.example123.interdim.net AAAA──▶ edge /128 :80/:443
                                                      │  cococoir-edge
                                                      │  (blind L4 forward)
                                                      ▼
                                     WireGuard (10.10.0.1/24, dial-out)
                                                      │
home box ──cococoir-client──▶ 127.0.0.1:80/443 ──▶ Caddy (ACME via tunnel)
```

Caddy on the home box gets real Let's Encrypt certs because the ACME
challenge traffic rides the same blind forwards as everything else.

## Setup

```bash
# 1. Set the Hetzner token in the secretspec provisioning store
#    (never committed). Create a write-enabled token at
#    console.hetzner.cloud -> Security -> API Tokens.
nix run .#secretspec -- set HETZNER_TOKEN '<your-token>' \
  -p provisioning_store -P provisioning -f ./secretspec.toml --reason "first-time setup"

# 2. Tooling.
nix develop  # or: nix shell nixpkgs#opentofu nixpkgs#jq

# 3. Variables.
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
# edit: domain, customer, ssh_public_key

# 4. Provision everything.
bash scripts/provision-edge.sh
```

`provision-edge.sh` resolves the token + admin key through the
secretspec CLI (profiles.provisioning, scopes `token`/`provision`),
runs `tofu apply` (server + firewall + ssh key + DNS zone + records +
renders the customer NixOS config), installs Nix on the stock Debian
image, applies the edge config with `system-manager switch`, and wires
the edge WG tunnel (throwaway key — the binary owns the real identity
at runtime).

## After provisioning

1. **Point interdim.net's NS records at Hetzner's nameservers**
   (`tofu output nameservers`) at your registrar. Until then the zone
   exists but is not authoritative.
2. **Customer box** (home machine, NixOS): apply
   `remote-infra/nix/example123.nix` on it (it is the full v2 product
   + the tunnel client), fill in its real btrfs disks. Its WG tunnel
   peer is wired from the edge's `/pubkey` at signup (deferred); today
   the render brings the interface up with no peers.
3. **Verify**: `bash remote-infra/scripts/demo-verify.sh` from an
   IPv6-native client and an IPv4 client.

## Modifying later

Everything is declarative. To change something:

- **Server/location/image**: `tofu/variables.tf`, re-apply.
- **Another customer**: add a `/128` derivation in `main.tf`, a record
  in `dns.tf`; the WG peer is registered via the control plane's
  `/signup` at runtime (deferred); re-apply + rebuild.
- **The edge box**: edit `system-manager/edge.nix`, then
  `nix run .#system-manager -- --target-host root@<edge> switch --flake .#edge --sudo`.
- **The customer NixOS config**: edit `tofu/templates/*.tftpl`,
  re-apply, then `nixos-rebuild` on the box. The rendered file is a
  derived artifact.

See `.specify/specs/ipv6-edge-demo/proposal.md` for the full arc.
