output "server_ipv4" {
  description = "Public IPv4 address of the created server"
  value       = module.vps.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the created server"
  value       = module.vps.ipv6_address
}

output "nameservers" {
  description = "Hetzner nameservers to configure at your domain registrar"
  value       = module.dns.nameservers
}

output "next_steps" {
  description = "What to do after provisioning"
  value       = <<-EOT
    Your server has been provisioned at ${module.vps.ipv4_address}.

    Next steps:
    1. Point your domain's NS records to Hetzner's nameservers:
       ${join("\n       ", module.dns.nameservers)}

    2. Install NixOS on the server (e.g. using nixos-anywhere):
       nix run github:nix-community/nixos-anywhere -- \
         --flake .#your-host \
         root@${module.vps.ipv4_address}

    3. Configure your home server as a rathole client pointing to:
       ${module.vps.ipv4_address}:2333
  EOT
}
