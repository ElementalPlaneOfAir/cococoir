# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir remote infra — render the machine configs.
#
# The configs are RENDERED from templates so the deployed addressing
# (edge IPv4, /64, customer /128, WG subnet, WG listen port) has
# exactly one source of truth: this tofu. Edit the .tftpl, re-apply,
# and the flake picks up the new config. The rendered files are
# checked in (they contain only public values: IPs).
#
# The edge box runs stock Debian via system-manager; its config is
# rendered here (system-manager/edge.nix) so the edge's /64 flows from
# tofu and cannot drift from DNS. The customer box (example123) is
# still NixOS.

resource "local_file" "edge_nix" {
  filename = "${path.module}/../system-manager/edge.nix"
  content = templatefile("${path.module}/templates/edge.nix.tftpl", {
    edge_ipv6_subnet = local.edge_ipv6_subnet
    edge_ipv4        = hcloud_server.edge.ipv4_address
    edge_primary_v6  = local.edge_primary_v6
    wg_subnet        = var.wg_subnet
    wg_listen_port   = tostring(var.wg_listen_port)
  })
}

resource "local_file" "example123_nix" {
  filename = "${path.module}/../nix/example123.nix"
  content = templatefile("${path.module}/templates/example123.nix.tftpl", {
    customer       = var.customer
    domain         = var.domain
    customer_wg_ip = local.customer_wg_ip
    ssh_pubkey     = var.ssh_public_key
  })
}
