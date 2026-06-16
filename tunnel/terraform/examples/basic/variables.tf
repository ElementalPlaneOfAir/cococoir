variable "server_name" {
  description = "Name for the Hetzner Cloud server"
  type        = string
  default     = "cococoir-proxy"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx22"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"
}

variable "domain" {
  description = "Domain name to configure DNS for (e.g. example.com)"
  type        = string
}

variable "ssh_public_key" {
  description = "Your SSH public key for server access"
  type        = string
}
