locals {
  ssh_keys = var.ssh_public_key != null ? concat([hcloud_ssh_key.this[0].id], var.ssh_key_ids) : var.ssh_key_ids
}

resource "hcloud_ssh_key" "this" {
  count      = var.ssh_public_key != null ? 1 : 0
  name       = "${var.name}-ssh-key"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "this" {
  name = "${var.name}-firewall"

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS (TCP)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS (UDP / HTTP/3 QUIC)
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Rathole control channel
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "2333"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # ICMP (ping)
  dynamic "rule" {
    for_each = var.allow_icmp ? [1] : []
    content {
      direction  = "in"
      protocol   = "icmp"
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }

  # Extra rules
  dynamic "rule" {
    for_each = var.firewall_rules
    content {
      direction  = rule.value.direction
      protocol   = rule.value.protocol
      port       = rule.value.port
      source_ips = rule.value.source_ips
    }
  }
}

resource "hcloud_server" "this" {
  name        = var.name
  server_type = var.server_type
  image       = var.image
  location    = var.location
  ssh_keys    = local.ssh_keys
  firewall_ids = [hcloud_firewall.this.id]
  labels      = var.labels

  public_net {
    ipv4_enabled = true
    ipv6_enabled = var.enable_ipv6
  }
}
