# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Rendered by tofu from remote-infra/tofu/main.tf — do not hand-edit.
# Values below (IPs, WG subnet, WG pubkey) come from the server
# resource and .secrets/wg/*.pub. The WG PRIVATE key stays on the
# box at /etc/wireguard/edge-private.key (scp'd at provision time).
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

  # ── Disk layout (disko, driven by nixos-anywhere) ───────────────
  # Single disk: UEFI boot partition + btrfs root. The edge box keeps
  # no customer data, so a flat root is enough — no subvolumes, no
  # /data pool. Disko only runs at install time (nixos-anywhere);
  # nothing in this module repartitions a live box.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = ["fmask=0077" "dmask=0077"];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = ["-f"];
            subvolumes = {
              "/root" = {mountpoint = "/";};
              "/nix" = {mountpoint = "/nix";};
            };
          };
        };
      };
    };
  };

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Edge-only: no storage, no services, no OIDC.
  cococoir.storage.enable = false;
  cococoir.services.dex.enable = false;

  services.cococoir-edge.enable = true;

  # One forward per customer /128, per port (TCP :80 + :443). ACME
  # traffic rides the same forwards, so the customer's Caddy gets
  # real Let's Encrypt certs through the tunnel.
  environment.etc."cococoir-edge.json".text = ''[{"dest_addr":"10.10.0.2:80","listen_addr":"[2a01:4f9:c014:2c44::2]:80","proto":"tcp"},{"dest_addr":"10.10.0.2:443","listen_addr":"[2a01:4f9:c014:2c44::2]:443","proto":"tcp"}]'';

  # ── Static networking (per the NixOS-on-Hetzner wiki) ────────────
  networking.useDHCP = false;
  networking.interfaces.eth0 = {
    ipv4.addresses = [
      {
        address = "62.238.111.21";
        prefixLength = 32;
      }
    ];
    ipv4.routes = [
      {
        address = "172.31.1.1";
        prefixLength = 32;
        options.onlink = "true";
      }
    ];
    ipv6.addresses = [
      {
        address = "2a01:4f9:c014:2c44::1";
        prefixLength = 64;
      }
      {
        address = "2a01:4f9:c014:2c44::2";
        prefixLength = 128;
      }
    ];
  };
  networking.defaultGateway = {
    address = "172.31.1.1";
    interface = "eth0";
  };
  networking.defaultGateway6 = {
    address = "fe80::1";
    interface = "eth0";
  };

  # ── WireGuard server ─────────────────────────────────────────────
  networking.wireguard.interfaces.wg0 = {
    privateKeyFile = "/etc/wireguard/edge-private.key";
    listenPort = 51820;
    ips = ["10.10.0.1/24"];
    peers = [
      {
        publicKey = "bT0pcaYyB3/+cV1OKWey0x+ua0fwj/4851bCgS4SokA=";
        allowedIPs = ["10.10.0.2/32"];
      }
    ];
  };

  # ── Firewall ─────────────────────────────────────────────────────
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [80 443];
    allowedUDPPorts = [51820];
  };

  # ── Operator access ──────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtpDAeIfLOlZE5y/SaHQ8h60nqbPSWdStRsvux6ECbk nicole@vermissian"
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
}
