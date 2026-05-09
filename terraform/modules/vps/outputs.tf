output "server_id" {
  description = "ID of the created Hetzner Cloud server"
  value       = hcloud_server.this.id
}

output "ipv4_address" {
  description = "Public IPv4 address of the server"
  value       = hcloud_server.this.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 address of the server"
  value       = hcloud_server.this.ipv6_address
}

output "firewall_id" {
  description = "ID of the created firewall"
  value       = hcloud_firewall.this.id
}

output "ssh_key_id" {
  description = "ID of the created SSH key (if a public key was provided)"
  value       = var.ssh_public_key != null ? hcloud_ssh_key.this[0].id : null
}
