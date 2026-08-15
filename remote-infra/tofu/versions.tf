# SPDX-License-Identifier: AGPL-3.0-or-later
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.56.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
  }
}

# Single provider, single token: the modern hcloud provider manages
# both Cloud resources (server, firewall, ssh key) and DNS (zone,
# rrsets) via the GA DNS API. No separate hetznerdns provider, no
# second token. The token is read from the HCLOUD_TOKEN env var and
# never stored in the repo.
provider "hcloud" {}
