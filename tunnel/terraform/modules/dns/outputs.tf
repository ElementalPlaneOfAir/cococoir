output "zone_id" {
  description = "ID of the created DNS zone"
  value       = hetznerdns_zone.this.id
}

output "nameservers" {
  description = "Hetzner nameservers for this zone. Point your domain's NS records to these at your registrar."
  value       = hetznerdns_zone.this.ns
}

output "record_names" {
  description = "Names of created DNS records"
  value       = [for r in hetznerdns_record.this : r.name]
}
