# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress remote infra — the edge's addressing.
#
# Per-customer addresses live on a cluster-owned Hetzner Floating IPv6
# /64 (ADR-029): customer /128s carve from it, and a shared Floating
# IPv4 /32 carries the WG dial-out endpoint + the control-plane website.
# Both floats are *movable* between the pair's nodes, so failover is a
# float reassignment, never a DNS rewrite.
#
# Addressing has exactly one source of truth: this tofu. The rendered
# edge config and every DNS record derive from the floats here, so they
# cannot drift. The customer's /128 is <float /64>::2, the apex AAAA is
# <float /64>::1.
#
# Float placement is runtime-owned: tofu creates them UNASSIGNED and the
# edge's reconcile loop assigns them to the active node at boot and
# moves them on failover. Tofu never pins a float to a server — that
# would fight the reconcile loop and go stale the first time it moves.
#
# The box runs a stock Debian image managed by system-manager (see
# remote-infra/system-manager/edge.nix); the customer box (example123)
# is still NixOS, rendered from templates below. IPs and the WG subnet
# flow from tofu so there is exactly one source of truth for the
# deployed addressing. WG identities are owned at runtime by the
# fortress-edge binary (self-generates + serves its public key at
# GET /pubkey) — no key material is provisioned or stored here.

locals {
  # Customer addresses carve from the cluster's floating /64 — never a
  # node's auto /64 (ADR-029). `var.edge_ipv6_subnet` still overrides
  # for an operator who slices one /64 across several boxes. Defaulting
  # straight to the float resource means a dropped or renamed float
  # fails loudly at plan time; there is no silent fallback to a server
  # /64 for customers to get carved from.
  edge_ipv6_subnet = var.edge_ipv6_subnet != "" ? var.edge_ipv6_subnet : hcloud_floating_ip.cluster_v6.ip_network

  customer_ipv6   = cidrhost(local.edge_ipv6_subnet, 2) # <subnet>::2
  edge_primary_v6 = cidrhost(local.edge_ipv6_subnet, 1) # <subnet>::1
  shared_v4       = hcloud_floating_ip.shared_v4.ip_address
  edge_wg_ip      = cidrhost(var.wg_subnet, 1)          # 10.10.0.1
  customer_wg_ip  = cidrhost(var.wg_subnet, 2)          # 10.10.0.2
}

resource "hcloud_ssh_key" "operator" {
  name       = "fortress-operator"
  public_key = var.ssh_public_key
}

# The cluster's movable address pool (ADR-029). Both floats are created
# UNASSIGNED: the reconcile loop assigns them to the active node at boot
# and moves them on failover, so tofu never goes stale. The IPv6 float
# hands out a routed /64 (customers carve /128s from it); the IPv4 float
# is the one universal address (WG dial-out + control-plane website).
resource "hcloud_floating_ip" "cluster_v6" {
  name          = "fortress-cluster-v6"
  type          = "ipv6"
  home_location = var.location
}

resource "hcloud_floating_ip" "shared_v4" {
  name          = "fortress-shared-v4"
  type          = "ipv4"
  home_location = var.location
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
