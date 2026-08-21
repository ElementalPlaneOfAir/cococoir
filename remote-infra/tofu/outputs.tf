# SPDX-License-Identifier: AGPL-3.0-or-later
output "edge_ipv4" {
  description = "Edge box public IPv4."
  value       = hcloud_server.edge.ipv4_address
}

output "edge_wg_ip" {
  description = "The edge box's WireGuard tunnel IP (WG subnet .1)."
  value       = local.edge_wg_ip
}

output "edge_ipv6_network" {
  description = "Edge box routed IPv6 /64 (the address pool)."
  value       = local.edge_ipv6_subnet
}

output "customer_ipv6" {
  description = "The customer's /128 on the edge box (AAAA target)."
  value       = local.customer_ipv6
}

output "nameservers" {
  description = "Hetzner nameservers for the zone — point interdim.net's NS records here at your registrar for the zone to go live."
  value       = hcloud_zone.interdim.authoritative_nameservers.assigned
}

output "dns_zone_id" {
  description = "Hetzner DNS zone ID for the apex domain — the runtime DNS client provisions customer AAAA records into it."
  value       = hcloud_zone.interdim.id
}

output "domain" {
  description = "The apex domain (== DNS zone name) — the runtime DNS client writes customer hostnames under it."
  value       = var.domain
}

output "wg_public_keys" {
  description = "WireGuard public keys (from .secrets/) — the customer box config needs edge.pub, the edge config needs customer.pub."
  value = {
    edge     = local.edge_wg_pub
    customer = local.customer_wg_pub
  }
}
