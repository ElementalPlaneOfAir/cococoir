resource "hetznerdns_zone" "this" {
  name = var.zone_name
  ttl  = var.zone_ttl
}

resource "hetznerdns_record" "this" {
  for_each = { for r in var.records : "${r.name}_${r.type}" => r }

  zone_id = hetznerdns_zone.this.id
  name    = each.value.name
  type    = each.value.type
  value   = each.value.value
  ttl     = each.value.ttl
}
