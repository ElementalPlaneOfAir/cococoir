# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Edge box NixOS config — PLACEHOLDER values.
#
# This file is overwritten by `tofu apply` (remote-infra/tofu/render.tf
# renders templates/edge.nix.tftpl into this path). The placeholders
# below let the flake evaluate before provisioning. Do not hand-edit
# the rendered values; edit the template instead.
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    (import ../../nix/nixos-modules)
  ];

  system.stateVersion = "25.11";
  networking.hostName = "edge";

  # Edge-only: no storage, no services, no OIDC.
  cococoir.storage.enable = false;
  cococoir.services.dex.enable = false;

  services.cococoir-edge.enable = true;

  # Filled by tofu: one forward per customer /128, per port.
  environment.etc."cococoir-edge.json".text = builtins.toJSON {
    forwards = [
      {
        listen_addr = "[2001:db8::2]:80";
        proto = "tcp";
        dest_addr = "10.10.0.2:80";
      }
      {
        listen_addr = "[2001:db8::2]:443";
        proto = "tcp";
        dest_addr = "10.10.0.2:443";
      }
    ];
  };

  # Filled by tofu: real IPv4, box subnet, and customer /128. The
  # prefix length below is the box subnet's (default /64; a /72 or
  # /96 slice of a shared /64 when edge_ipv6_subnet is set).
  networking.useDHCP = false;
  networking.interfaces.ens3 = {
    ipv4.addresses = [
      {
        address = "1.2.3.4";
        prefixLength = 32;
      }
    ];
    ipv4.routes = [
      {
        address = "172.31.1.1";
        prefixLength = 32;
        options.onlink = true;
      }
    ];
    ipv6.addresses = [
      {
        address = "2001:db8::1";
        prefixLength = 64;
      }
      {
        address = "2001:db8::2";
        prefixLength = 128;
      }
    ];
  };
  networking.defaultGateway = {
    address = "172.31.1.1";
    interface = "ens3";
  };
  networking.defaultGateway6 = {
    address = "fe80::1";
    interface = "ens3";
  };

  # Filled by tofu: WG peer = the customer.
  networking.wireguard.interfaces.wg0 = {
    privateKeyFile = "/etc/wireguard/edge-private.key";
    listenPort = 51820;
    ips = ["10.10.0.1/24"];
    peers = [
      {
        publicKey = "CHANGE_ME_CUSTOMER_WG_PUBKEY";
        allowedIPs = ["10.10.0.2/32"];
      }
    ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [80 443];
    allowedUDPPorts = [51820];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtpDAeIfLOlZE5y/SaHQ8h60nqbPSWdStRsvux6ECbk nicole@vermissian"
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
}
