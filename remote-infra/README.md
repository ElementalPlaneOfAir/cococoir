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
│   ├── render.tf            # renders the NixOS configs from templates
│   ├── templates/           # edge.nix / example123.nix templates
│   ├── versions.tf          # hcloud + local providers
│   └── terraform.tfvars.example
├── nix/                     # RENDERED NixOS configs (checked in, public values)
│   ├── edge.nix             #   overwritten by tofu apply
│   └── example123.nix       #   overwritten by tofu apply
├── scripts/
│   ├── gen-wg-keys.sh       # WG keypairs -> .secrets/wg/ (gitignored)
│   └── provision-edge.sh    # gen keys -> tofu -> nixos-anywhere -> scp key
└── .secrets/                # gitignored: WG private keys, tofu state
```

## Why this shape

- **No first-party NixOS image on Hetzner** (confirmed via changelog
  2026-08). The box boots a disposable `ubuntu-24.04` and
  **nixos-anywhere** installs NixOS from the repo flake over SSH. This
  is the canonical Hetzner+NixOS path (NixOS wiki).
- **One source of truth for addressing.** The edge IPv4, the routed
  `/64`, and the customer `/128` are derived once in `tofu/main.tf`
  (`cidrhost`) and flow into the DNS records AND the rendered NixOS
  configs. Change a variable → re-apply → both stay consistent.
- **Secrets never in git.** The Hetzner token comes from the
  `HCLOUD_TOKEN` env var. WireGuard private keys are generated into
  `.secrets/` (gitignored) and scp'd to the boxes at provision time.
  Only IPs + WG *public* keys land in the rendered (checked-in)
  NixOS configs — those are not secrets.

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
# 1. Token (never committed). Create a write-enabled token at
#    console.hetzner.cloud -> Security -> API Tokens.
mkdir -p ~/.secrets
echo 'your-token' > ~/.secrets/HETZNER_API_KEY
chmod 600 ~/.secrets/HETZNER_API_KEY

# 2. Tooling.
nix develop  # or: nix shell nixpkgs#opentofu nixpkgs#nixos-anywhere \
             #         nixpkgs#wireguard-tools nixpkgs#jq

# 3. Variables.
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
# edit: domain, customer, ssh_public_key

# 4. Provision everything.
bash scripts/provision-edge.sh
```

`provision-edge.sh` generates the WG keypairs, runs `tofu apply`
(server + firewall + ssh key + DNS zone + records + renders the NixOS
configs), installs NixOS with nixos-anywhere, and scp's the edge WG
private key onto the box.

## After provisioning

1. **Point interdim.net's NS records at Hetzner's nameservers**
   (`tofu output nameservers`) at your registrar. Until then the zone
   exists but is not authoritative.
2. **Customer box** (home machine, NixOS): apply
   `remote-infra/nix/example123.nix` on it (it is the full v2 product
   + the tunnel client), fill in its real btrfs disks, then
   `scp remote-infra/.secrets/wg/customer.private` to
   `/etc/wireguard/example123-private.key` and restart the WG + client
   units.
3. **Verify**: `bash remote-infra/scripts/demo-verify.sh` from an
   IPv6-native client and an IPv4 client.

## Modifying later

Everything is declarative. To change something:

- **Server/location/image**: `tofu/variables.tf`, re-apply.
- **Another customer**: add a `/128` derivation in `main.tf`, a record
  in `dns.tf`, and a peer in the edge template; re-apply + rebuild.
- **The NixOS configs**: edit `tofu/templates/*.tftpl`, re-apply, then
  `nixos-anywhere` / `nixos-rebuild` again. The rendered files are
  derived artifacts.

See `.specify/specs/ipv6-edge-demo/proposal.md` for the full arc.
