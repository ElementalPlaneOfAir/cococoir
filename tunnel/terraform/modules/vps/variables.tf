variable "name" {
  description = "Name of the Hetzner Cloud server"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (e.g. cx22, cpx11, cpx21)"
  type        = string
  default     = "cx22"
}

variable "location" {
  description = "Hetzner datacenter location (e.g. nbg1, fsn1, hel1, ash)"
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "OS image to install (e.g. ubuntu-24.04, debian-12)"
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_public_key" {
  description = "SSH public key to install on the server. If null, no key is created."
  type        = string
  default     = null
}

variable "ssh_key_ids" {
  description = "List of existing Hetzner SSH key IDs to attach to the server"
  type        = list(number)
  default     = []
}

variable "labels" {
  description = "Labels to attach to the server"
  type        = map(string)
  default     = {}
}

variable "enable_ipv6" {
  description = "Enable IPv6 for the server"
  type        = bool
  default     = true
}

variable "firewall_rules" {
  description = "Additional firewall rules to add beyond the defaults (SSH, HTTP, HTTPS, rathole)"
  type = list(object({
    direction  = string
    protocol   = string
    port       = optional(string)
    source_ips = list(string)
  }))
  default = []
}

variable "allow_icmp" {
  description = "Allow ICMP (ping) traffic"
  type        = bool
  default     = true
}
