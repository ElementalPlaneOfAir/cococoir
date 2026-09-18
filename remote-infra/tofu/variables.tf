# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress remote infra — input variables.
#
# Public/derived values only, all sourced from secrets/facts.json
# (passed via -var-file by provision-edge.sh). The single secret (Hetzner
# API token) comes from HCLOUD_TOKEN (resolved by provision-edge.sh via
# `secretspec export -S token`). WG identities are owned at runtime by
# the edge binary — nothing here provisions key material.
variable "server_name" {
  description = "Name of the edge box."
  type        = string
}

variable "server_type" {
  description = "Hetzner server type for the edge box. The US locations (hil/ash/sin) offer only cpx*/ccx* — cx* is EU-only."
  type        = string
}

variable "location" {
  description = "Hetzner location (nbg1, fsn1, hel1, ash, hil, sin)."
  type        = string
}

variable "bootstrap_image" {
  description = "Stock OS image for the edge box. system-manager applies the fortress config on top; no first-party NixOS image exists on Hetzner (confirmed via changelog 2026-08)."
  type        = string
}

variable "ipv4_gateway" {
  description = "Hetzner IPv4 gateway (onlink). Same 172.31.1.1 across locations."
  type        = string
}

variable "domain" {
  description = "Apex domain the customer services live under (e.g. proletariat.tech)."
  type        = string
}

variable "customer" {
  description = "Customer username. *.&lt;customer&gt;.&lt;domain&gt; AAAA records point at their /128 on the edge box."
  type        = string
}

variable "ssh_public_key" {
  description = "Operator SSH public key injected into the edge box and the customer box."
  type        = string
}

variable "wg_subnet" {
  description = "WireGuard tunnel subnet (edge .1, customer .2)."
  type        = string
}

variable "wg_listen_port" {
  description = "WireGuard listen port on the edge box."
  type        = number
}

variable "edge_ipv6_subnet" {
  description = "The subnet customers carve /128s from. Default: the box's own routed /64 (ADR-025). Set this when the operator manages one shared /64 and hands this box a /72 or /96 slice of it (e.g. 2a01:4f8:c17:1:ab00::/72). Must be byte-aligned /64..=/112."
  type        = string
}