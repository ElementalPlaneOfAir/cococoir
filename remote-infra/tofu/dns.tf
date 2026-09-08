# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir remote infra — DNS for interdim.net.
#
# The zone is created here (the user owns the domain but has no
# Hetzner zone yet). Records follow the IPv6 vision doc + ADR-029:
#   interdim.net              A    -> shared Floating IPv4 /32 (WG dial-out
#                                     endpoint + control-plane website)
#   interdim.net              AAAA -> <float /64>::1
#   *.example123.interdim.net AAAA -> customer /128 carved from the float /64
# The apex A/AAAA never change on failover — the floats move, DNS stays.
# The operator must point interdim.net's NS records at Hetzner's
# nameservers (output "nameservers") for the zone to go live.

resource "hcloud_zone" "interdim" {
  name = var.domain
  mode = "primary"
  ttl  = 300
}

# Apex: the shared Floating IPv4 /32. This is the one universal address
# (most homes are v4-only), carrying the WG dial-out endpoint and the
# control-plane website. It moves with the pair on failover; DNS never
# changes.
resource "hcloud_zone_rrset" "apex_a" {
  zone = hcloud_zone.interdim.name
  name = "@"
  type = "A"
  records = [
    { value = local.shared_v4 },
  ]
}

# Apex IPv6: the cluster floating /64's ::1 — not a node's auto /64.
resource "hcloud_zone_rrset" "apex_aaaa" {
  zone = hcloud_zone.interdim.name
  name = "@"
  type = "AAAA"
  records = [
    { value = local.edge_primary_v6 },
  ]
}

# The customer's wildcard: every service subdomain resolves to the
# customer's /128 carved from the cluster floating /64. Caddy
# SNI-routes per service on the customer box, so one address serves the
# whole jar.
resource "hcloud_zone_rrset" "customer_aaaa" {
  zone = hcloud_zone.interdim.name
  name = "*.${var.customer}"
  type = "AAAA"
  records = [
    { value = local.customer_ipv6 },
  ]
}
