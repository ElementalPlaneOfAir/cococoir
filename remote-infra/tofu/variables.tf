# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir remote infra — input variables.
#
# Public/derived values only. The single secret (Hetzner API token)
# comes from HCLOUD_TOKEN (resolved by provision-edge.sh via
# `secretspec export -S token`). WG identities are owned at runtime by
# the edge binary — nothing here provisions key material.
variable "server_name" {
  description = "Name of the edge box."
  type        = string
  default     = "edge"
}

variable "server_type" {
  description = "Hetzner server type for the edge box."
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner location (nbg1, fsn1, hel1, ash, sin)."
  type        = string
  default     = "hel1"
}

variable "bootstrap_image" {
  description = "Stock OS image for the edge box. system-manager applies the cococoir config on top; no first-party NixOS image exists on Hetzner (confirmed via changelog 2026-08)."
  type        = string
  default     = "debian-12"
}

variable "ipv4_gateway" {
  description = "Hetzner IPv4 gateway (onlink). Same 172.31.1.1 across locations."
  type        = string
  default     = "172.31.1.1"
}

variable "domain" {
  description = "Apex domain the customer services live under (e.g. interdim.net)."
  type        = string
}

variable "customer" {
  description = "Customer username. *.&lt;customer&gt;.&lt;domain&gt; AAAA records point at their /128 on the edge box."
  type        = string
  default     = "example123"
}

variable "ssh_public_key" {
  description = "Operator SSH public key injected into the edge box and the customer box."
  type        = string
}

variable "wg_subnet" {
  description = "WireGuard tunnel subnet (edge .1, customer .2)."
  type        = string
  default     = "10.10.0.0/24"
}

variable "wg_listen_port" {
  description = "WireGuard listen port on the edge box."
  type        = number
  default     = 51820
}

variable "edge_ipv6_subnet" {
  description = "The edge box's routed IPv6 subnet (CIDR). Default: Hetzner's per-server /64. Set this when the operator manages one shared /64 and hands this box a /72 or /96 slice of it (e.g. 2a01:4f8:c17:1:ab00::/72). Must be byte-aligned /64..=/112."
  type        = string
  default     = ""
}
