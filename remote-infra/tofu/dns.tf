# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress remote infra — DNS for proletariat.tech.
#
# The zone is created here (the operator owns the domain but has no
# Hetzner zone yet). Records follow the IPv6 vision doc + ADR-025:
#   proletariat.tech              A    -> edge box's own IPv4 (WG dial-out
#                                     endpoint + control-plane website)
#   proletariat.tech              AAAA -> <server /64>::1
#   *.example123.proletariat.tech AAAA -> customer /128 carved from the box /64
#   resend._domainkey             TXT  -> Resend DKIM key
#   rsend / send                  CNAME-> Resend envelope-from subdomains
#   _dmarc                        TXT  -> DMARC (p=none, monitor mode)
#
# Single instance: no floats, no failover, DNS points at the one box.
# A CNAME at the old domain bridges until a formal migration.

resource "hcloud_zone" "proletariat" {
  name = var.domain
  mode = "primary"
  ttl  = 300
}

# Apex: the edge box's own IPv4. Most homes are v4-only, so this carries
# the WG dial-out endpoint + the control-plane website.
resource "hcloud_zone_rrset" "apex_a" {
  zone = hcloud_zone.proletariat.name
  name = "@"
  type = "A"
  records = [
    { value = hcloud_server.edge.ipv4_address },
  ]
}

# Apex IPv6: the box /64's ::1.
resource "hcloud_zone_rrset" "apex_aaaa" {
  zone = hcloud_zone.proletariat.name
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
  zone = hcloud_zone.proletariat.name
  name = "*.${var.customer}"
  type = "AAAA"
  records = [
    { value = local.customer_ipv6 },
  ]
}

# Transactional mail: Resend serves the SmtpMailer (magic-link verify +
# password reset). DKIM signs from proletariat.tech; the CNAMEs delegate
# the envelope-from subdomains so Resend owns their SPF/bounce handling.
# Verify the domain in the Resend dashboard after the first apply.
resource "hcloud_zone_rrset" "resend_dkim" {
  zone = hcloud_zone.proletariat.name
  name = "resend._domainkey"
  type = "TXT"
  records = [
    { value = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHulxstMhP8T4NRTBX3/T+MuYGxMCLGaJENwaGRh25Fr8RjPFQb1vrrmeSMduyDRfqpeMGkXIQHdgaS4Qa2F0lP5AztD4FJyHZgqseKQ6mC9XNKAsACD3HpIE6LJQG6F7FFIvwsEufiSmrU8yL3QwdsS7dOGrFn3CBGBBSvb2nOQIDAQAB" },
  ]
}

resource "hcloud_zone_rrset" "resend_envelope_rsend" {
  zone = hcloud_zone.proletariat.name
  name = "rsend"
  type = "CNAME"
  records = [
    { value = "rsend.forge.rmta.net." },
  ]
}

resource "hcloud_zone_rrset" "resend_envelope_send" {
  zone = hcloud_zone.proletariat.name
  name = "send"
  type = "CNAME"
  records = [
    { value = "send.forge.rmta.net." },
  ]
}

resource "hcloud_zone_rrset" "dmarc" {
  zone = hcloud_zone.proletariat.name
  name = "_dmarc"
  type = "TXT"
  records = [
    { value = "v=DMARC1; p=none" },
  ]
}