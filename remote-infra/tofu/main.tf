# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress remote infra — the edge's addressing.
#
# ONE edge box with its own public IPv4 + routed IPv6 /64. Customer /128s
# carve from the box's /64, and the box's own IPv4 carries the WG dial-out
# endpoint + the control-plane website. This is deliberately a single
# instance: the HA pair (ADR-029) was cut before ship — failover for a
# fleet this size is a rebuild runbook, not a hot-hot state machine (the
# T4 lease machinery was deleted from the tree when the pair was cut).
#
# Addressing has exactly one source of truth: this tofu. The rendered
# edge config and every DNS record derive from the server here, so they
# cannot drift. The customer's /128 is <server /64>::2, the apex AAAA is
# <server /64>::1.
#
# The control-plane store is an EXTERNAL managed Redis (secret REDIS_URL,
# TLS rediss://), never a local redis on the box — that stays from the
# ADR-029 design because it is the control plane's persistence, not HA.
#
# The box runs a stock Debian image managed by system-manager (see
# remote-infra/system-manager/edge.nix); the customer box (example123)
# is still NixOS, rendered from templates below. IPs and the WG subnet
# flow from tofu so there is exactly one source of truth for the
# deployed addressing. WG identities are owned at runtime by the
# fortress-edge binary (self-generates + serves its public key at
# GET /pubkey) — no key material is provisioned or stored here.

locals {
  # Customer addresses carve from the box's own routed /64 (ADR-025).
  # `var.edge_ipv6_subnet` still overrides for an operator who slices one
  # /64 across several boxes. Defaulting straight to the server's /64
  # means a dropped or renamed server fails loudly at plan time; there is
  # no silent fallback for customers to get carved from.
  edge_ipv6_subnet = var.edge_ipv6_subnet != "" ? var.edge_ipv6_subnet : hcloud_server.edge.ipv6_network

  customer_ipv6   = cidrhost(local.edge_ipv6_subnet, 2) # <subnet>::2
  edge_primary_v6 = cidrhost(local.edge_ipv6_subnet, 1) # <subnet>::1
  edge_wg_ip      = cidrhost(var.wg_subnet, 1)          # 10.10.0.1
  customer_wg_ip  = cidrhost(var.wg_subnet, 2)          # 10.10.0.2
}

resource "hcloud_ssh_key" "operator" {
  name       = "fortress-operator"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "edge" {
  name = "${var.server_name}-firewall"

  # SSH — operator access + system-manager bootstrap.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP / HTTPS — the forwarded customer traffic (ACME included).
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # WireGuard — the customer's dial-out tunnel.
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = tostring(var.wg_listen_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # ICMP (ping) — reachability debugging for the demo.
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "edge" {
  name         = var.server_name
  server_type  = var.server_type
  location     = var.location
  image        = var.bootstrap_image
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.edge.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true # -> routed /64 subnet
  }
}