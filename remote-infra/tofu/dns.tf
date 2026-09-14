# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress remote infra — DNS for interdim.net.
#
# The zone is created here (the operator owns the domain but has no
# Hetzner zone yet). Records follow the IPv6 vision doc + ADR-025:
#   interdim.net              A    -> edge box's own IPv4 (WG dial-out
#                                     endpoint + control-plane website)
#   interdim.net              AAAA -> <server /64>::1
#   *.example123.interdim.net AAAA -> customer /128 carved from the box /64
#
# Single instance: no floats, no failover, DNS points at the one box.
# A CNAME at the old domain bridges until a formal migration.

resource "hcloud_zone" "interdim" {
  name = var.domain
  mode = "primary"
  ttl  = 300
}

# Apex: the edge box's own IPv4. Most homes are v4-only, so this carries
# the WG dial-out endpoint + the control-plane website.
resource "hcloud_zone_rrset" "apex_a" {
  zone = hcloud_zone.interdim.name
  name = "@"
  type = "A"
  records = [
    { value = hcloud_server.edge.ipv4_address },
  ]
}

# Apex IPv6: the box /64's ::1.
resource "hcloud_zone_rrset" "apex_aaaa" {
  zone = hcloud_zone.interdim.name
  name = "@"
  type = "AAAA"
  records = [
    { value = local.edge_primary_v6 },
  ]
}

# The customer's wildcard: every service subdomain resolves to the
# customer's /128 carved from the box /64. Caddy SNI-routes per service
# on the customer box, so one address serves the whole jar.
resource "hcloud_zone_rrset" "customer_aaaa" {
  zone = hcloud_zone.interdim.name
  name = "*.${var.customer}"
  type = "AAAA"
  records = [
    { value = local.customer_ipv6 },
  ]
}