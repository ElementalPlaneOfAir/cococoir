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

resource "local_file" "edge_nix" {
  filename = "${path.module}/../nix/edge.nix"
  content = templatefile("${path.module}/templates/edge.nix.tftpl", {
    edge_ipv4          = hcloud_server.edge.ipv4_address
    edge_ipv6_primary  = local.edge_primary_v6
    edge_ipv6_customer = local.customer_ipv6
    edge_interface     = var.edge_interface
    ipv4_gateway       = var.ipv4_gateway
    edge_wg_ip         = local.edge_wg_ip
    customer_wg_ip     = local.customer_wg_ip
    customer_wg_pub    = local.customer_wg_pub
    wg_listen_port     = tostring(var.wg_listen_port)
    ssh_pubkey         = var.ssh_public_key
    edge_forwards_json = jsonencode([
      {
        listen_addr = "[${local.customer_ipv6}]:80"
        proto       = "tcp"
        dest_addr   = "${local.customer_wg_ip}:80"
      },
      {
        listen_addr = "[${local.customer_ipv6}]:443"
        proto       = "tcp"
        dest_addr   = "${local.customer_wg_ip}:443"
      },
    ])
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
