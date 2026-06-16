terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45.0"
    }
    hetznerdns = {
      source  = "germanbrew/hetznerdns"
      version = ">= 3.1.0"
    }
  }
}

provider "hcloud" {
  # Set HCLOUD_TOKEN environment variable
}

provider "hetznerdns" {
  # Set HETZNER_DNS_API_TOKEN environment variable
}
