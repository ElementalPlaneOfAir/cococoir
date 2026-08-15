# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir remote infra — DNS for interdim.net.
#
# The zone is created here (the user owns the domain but has no
# Hetzner zone yet). Records follow the IPv6 vision doc:
#   interdim.net              A    -> edge IPv4
#   interdim.net              AAAA -> edge primary /128
#   *.example123.interdim.net AAAA -> customer /128 on the edge
# The operator must point interdim.net's NS records at Hetzner's
# nameservers (output "nameservers") for the zone to go live.

resource "hcloud_zone" "interdim" {
  name = var.domain
  mode = "primary"
  ttl  = 300
}

# Apex: the single IPv4 address.
resource "hcloud_zone_rrset" "apex_a" {
  zone = hcloud_zone.interdim.name
  name = "@"
  type = "A"
  records = [
    { value = hcloud_server.edge.ipv4_address },
  ]
}

# Apex IPv6: the box's primary /128 (from the /64).
resource "hcloud_zone_rrset" "apex_aaaa" {
  zone = hcloud_zone.interdim.name
  name = "@"
  type = "AAAA"
  records = [
    { value = local.edge_primary_v6 },
  ]
}

# The customer's wildcard: every service subdomain resolves to the
# customer's /128 on the edge box. Caddy SNI-routes per service on
# the customer box, so one address serves the whole jar.
resource "hcloud_zone_rrset" "customer_aaaa" {
  zone = hcloud_zone.interdim.name
  name = "*.${var.customer}"
  type = "AAAA"
  records = [
    { value = local.customer_ipv6 },
  ]
}
