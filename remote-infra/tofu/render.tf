# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir remote infra — render the NixOS machine configs.
#
# The NixOS configs live in remote-infra/nix/ but are RENDERED from
# these templates so the deployed addressing (edge IPv4, /64, customer
# /128, WG subnet, WG public keys) has exactly one source of truth:
# this tofu. Edit the .tftpl, re-apply, and nixos-anywhere / the flake
# picks up the new config. The rendered files are checked in (they
# contain only public values: IPs + WG public keys).

locals {
  edge_ipv6_prefix_len = parseint(element(split("/", local.edge_ipv6_subnet), 1), 10)
}

resource "local_file" "edge_nix" {
  filename = "${path.module}/../nix/edge.nix"
  content = templatefile("${path.module}/templates/edge.nix.tftpl", {
    edge_ipv6_subnet  = local.edge_ipv6_subnet
    edge_wg_ip        = local.edge_wg_ip
    wg_subnet         = var.wg_subnet
    wg_listen_port    = tostring(var.wg_listen_port)
    edge_disk_device  = var.edge_disk_device
    ssh_pubkey        = var.ssh_public_key
  })
}

resource "local_file" "example123_nix" {
  filename = "${path.module}/../nix/example123.nix"
  content = templatefile("${path.module}/templates/example123.nix.tftpl", {
    customer       = var.customer
    domain         = var.domain
    edge_ipv4      = hcloud_server.edge.ipv4_address
    edge_wg_ip     = local.edge_wg_ip
    customer_wg_ip = local.customer_wg_ip
    edge_wg_pub    = local.edge_wg_pub
    wg_listen_port = tostring(var.wg_listen_port)
    ssh_pubkey     = var.ssh_public_key
  })
}
