# Tunnel Terraform Modules

Reusable OpenTofu modules for provisioning the VPS + DNS side of a
cococoir deployment. Everything uses **Hetzner** so you only need one
account and one API key.

These modules used to live at the cococoir repo root; they moved here
as part of phase 4 of the great simplification. See `../README.md`.

## Why Hetzner?

- Best price-to-performance for low-end VPS instances
- Native DNS hosting (free)
- Excellent API and Terraform provider support
- EU-based, privacy-respecting alternative to Cloudflare + DigitalOcean

## Modules

### `modules/vps`

Provisions a Hetzner Cloud server with:
- Pre-configured firewall (SSH, HTTP, HTTPS, rathole control)
- SSH key injection
- IPv4 + optional IPv6

### `modules/dns`

Manages a Hetzner DNS zone with:
- Automatic zone creation
- A, AAAA, CNAME, TXT records
- Nameserver output for registrar configuration

## Quick Start

```bash
# Enter the dev shell with OpenTofu
nix develop   # from the tunnel/ directory

cd examples/basic
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your domain and SSH key

export HCLOUD_TOKEN="your-hetzner-cloud-token"
export HETZNER_DNS_API_TOKEN="your-hetzner-dns-token"

tofu init
tofu apply
```

After apply, update your domain registrar's nameservers to the ones
shown in the tofu output.

## Directory Layout

```
terraform/
├── modules/
│   ├── vps/          # Hetzner Cloud server + firewall
│   └── dns/          # Hetzner DNS zone + records
├── examples/
│   └── basic/        # Complete working example
└── README.md
```
