# Basic Cococoir Infrastructure Example

This example provisions a minimal Cococoir stack on Hetzner Cloud:
- A VPS with firewall rules for rathole + HTTPS
- DNS zone and records pointing your domain to the server

## Prerequisites

1. A Hetzner Cloud account with billing enabled
2. A Hetzner DNS account (free, uses same login as Cloud)
3. A domain name purchased from any registrar
4. Terraform installed

## Setup

1. Create API tokens:
   - [Hetzner Cloud Console](https://console.hetzner.cloud/) → Security → API Tokens
   - [Hetzner DNS Console](https://dns.hetzner.com/) → Account → API Tokens

2. Set environment variables:
   ```bash
   export HCLOUD_TOKEN="your-hetzner-cloud-token"
   export HETZNER_DNS_API_TOKEN="your-hetzner-dns-token"
   ```

3. Copy and edit the variables:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your domain and SSH key
   ```

4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

5. After apply, note the nameservers output and update your domain's NS records at your registrar to point to Hetzner's nameservers.

## What's Created

| Resource | Description |
|----------|-------------|
| Server | Hetzner Cloud VPS |
| Firewall | Allows 22 (SSH), 80 (HTTP), 443 (TCP+UDP), 2333 (rathole) |
| DNS Zone | Managed by Hetzner DNS |
| A/AAAA Records | `@` and `*` pointing to your server |

## Costs

At time of writing, Hetzner Cloud pricing:
- **CX22** (2 vCPU, 4 GB RAM): ~€4.51/month
- **CPX11** (2 vCPU, 2 GB RAM): ~€4.51/month
- Hetzner DNS: Free
