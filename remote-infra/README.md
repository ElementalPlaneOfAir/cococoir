# Fortress remote infra

Provisioning for the IPv6 edge demo — the "global IP box" from
`writing/human/architecture_of_ipv6.md`, plus the DNS that fronts it.
Everything here is **OpenTofu** (single `hcloud` provider, single
HCLOUD_TOKEN, DNS managed through the GA Hetzner DNS API) so the whole
deployment can be reviewed and modified in one place.

## Layout

```
secrets/                     # THE folder a fresh-clone operator edits
├── facts.json               # every public value (committed plaintext)
└── secrets.enc.yaml         # sops store (committed as age ciphertext)
remote-infra/
├── tofu/                    # OpenTofu: the source of truth
│   ├── main.tf              # server, firewall, ssh key, address derivation
│   ├── dns.tf               # proletariat.tech zone + records
│   ├── render.tf            # renders the edge (system-manager) config
│   ├── templates/           # edge.nix template
│   └── versions.tf          # hcloud + local providers
├── system-manager/          # edge box config (stock Debian, no NixOS)
│   └── edge.nix             #   applied via system-manager switch
└── scripts/
    └── provision-edge.sh    # secretspec resolve -> tofu -> nix install -> system-manager -> wire WG
```

## Why this shape

- **No first-party NixOS image on Hetzner** (confirmed via changelog
  2026-08). The edge box boots a stock `debian-12` image and
  **system-manager** applies the fortress config on top (systemd
  services, packages, `/etc` files) without taking over the OS. This
  sidesteps the disko/fstab/NIC boot failures that plagued the old
  NixOS edge. Customer boxes are the operator's own NixOS machines —
  this repo is the library/template they import (`nixosModules.default`
  + `flake.lib.mkPkgs`), not a rendered config.
- **One source of truth for addressing.** The edge IPv4 and the routed
  `/64` are derived once in `tofu/main.tf` (`cidrhost`) and flow into
  the DNS records and the provision script's WireGuard config. Change a
  variable → re-apply → everything stays consistent. Customer `/128`s
  are carved from the box's `/64` at signup by the control plane
  (ADR-025) — never rendered here.
- **Secrets: one folder, `secrets/`.** `facts.json` holds every
  public value plaintext (committed — diffable in review). The Hetzner
  token + generated admin key live in the sops store
  `secrets/secrets.enc.yaml` (age-encrypted at rest, committed as
  ciphertext — re-point `age_recipients` in `secretspec.toml` to your
  own public key before use), resolved via `nix run .#secretspec --
  export -P provisioning -S <scope>`. WG identities are owned at
  runtime by the edge binary — nothing here provisions key material.
  Only IPs land in the rendered (checked-in) configs.

## The IPv6 model being provisioned

```
cellular (IPv6) ──<customer>.proletariat.tech AAAA──▶ edge /128 :80/:443
                                                  │  fortress-edge
                                                  │  (blind L4 forward)
                                                  ▼
                                 WireGuard (10.10.0.1/24, dial-out)
                                                  │
home box ──fortress-client──▶ 127.0.0.1:80/443 ──▶ Caddy (ACME via tunnel)
```

Caddy on the home box gets real Let's Encrypt certs because the ACME
challenge traffic rides the same blind forwards as everything else.

## Setup

```bash
# 1. Re-encrypt the store to YOUR age key (public key already in
#    secretspec.toml's age_recipients — replace it, run sops updatekeys).
#    Then set a write-enabled Hetzner token (console.hetzner.cloud ->
#    Security -> API Tokens) in the provisioning store:
nix run .#secretspec -- set HETZNER_TOKEN '<your-token>' \
  -p provisioning_store -P provisioning -f ./secretspec.toml --reason "first-time setup"

# 2. Tooling.
nix develop  # or: nix shell nixpkgs#opentofu nixpkgs#jq

# 3. Values. Edit secrets/facts.json — domain, ssh_public_key,
#    server type/location, WG subnet/port, all of it.

# 4. Provision everything.
bash scripts/provision-edge.sh
```

`provision-edge.sh` resolves the token + admin key through the
secretspec CLI (profiles.provisioning, scopes `token`/`provision`),
runs `tofu apply` (server + firewall + ssh key + DNS zone + records +
renders the edge config), installs Nix on the stock Debian
image, applies the edge config with `system-manager switch`, and wires
the edge WG tunnel (throwaway key — the binary owns the real identity
at runtime).

## After provisioning

1. **Point proletariat.tech's NS records at Hetzner's nameservers**
   (`tofu output nameservers`) at your registrar. Until then the zone
   exists but is not authoritative.
2. **Customer box** (home machine, NixOS): this repo is the
   library/template — import `fortress.nixosModules.default` +
   `fortress.lib.mkPkgs` into the box's flake (the full v2 product +
   the tunnel client), fill in its real btrfs disks. No rendered
   customer config ships here; each customer is provisioned at runtime
   by the control plane (invite → approve → `/128`).
3. **Verify**: `bash remote-infra/scripts/demo-verify.sh <baseDomain>`
   from an IPv6-native client and an IPv4 client.

## Modifying later

Everything is declarative. To change something:

- **Server/location/image**: `secrets/facts.json`, then re-run
  `scripts/provision-edge.sh`.
- **Another customer**: the `/128` + DNS are provisioned by the control
  plane at signup (`POST /signup` → WG peer + AAAA record) — no tofu
  edit, no re-apply.
- **The edge box**: edit `system-manager/edge.nix`, then
  `nix run .#system-manager -- --target-host root@<edge> switch --flake .#edge --sudo`.
- **The edge config template**: edit `tofu/templates/edge.nix.tftpl`,
  re-apply to re-render `system-manager/edge.nix`.

See `.specify/specs/ipv6-edge-demo/proposal.md` for the full arc.
