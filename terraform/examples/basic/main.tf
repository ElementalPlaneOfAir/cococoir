module "vps" {
  source = "../../modules/vps"

  name           = var.server_name
  server_type    = var.server_type
  location       = var.location
  ssh_public_key = var.ssh_public_key
}

module "dns" {
  source = "../../modules/dns"

  zone_name = var.domain
  records = [
    {
      name  = "@"
      type  = "A"
      value = module.vps.ipv4_address
      ttl   = 300
    },
    {
      name  = "*"
      type  = "A"
      value = module.vps.ipv4_address
      ttl   = 300
    },
    {
      name  = "@"
      type  = "AAAA"
      value = module.vps.ipv6_address
      ttl   = 300
    },
    {
      name  = "*"
      type  = "AAAA"
      value = module.vps.ipv6_address
      ttl   = 300
    },
  ]
}
