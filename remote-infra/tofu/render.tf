# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress remote infra — render the machine configs.
#
# The configs are RENDERED from templates so the deployed addressing
# (edge IPv4, /64, WG subnet, WG listen port, domain) has
# exactly one source of truth: this tofu. Edit the .tftpl, re-apply,
# and the flake picks up the new config. The rendered files are
# checked in (they contain only public values: IPs + domain).
#
# The edge box runs stock Debian via system-manager; its config is
# rendered here (system-manager/edge.nix) so the edge's /64 flows from
# tofu and cannot drift from DNS.

resource "local_file" "edge_nix" {
  filename = "${path.module}/../system-manager/edge.nix"
  content = templatefile("${path.module}/templates/edge.nix.tftpl", {
    edge_ipv6_subnet = local.edge_ipv6_subnet
    edge_ipv4        = hcloud_server.edge.ipv4_address
    edge_primary_v6  = local.edge_primary_v6
    wg_subnet        = var.wg_subnet
    wg_listen_port   = tostring(var.wg_listen_port)
    domain           = var.domain
  })
}