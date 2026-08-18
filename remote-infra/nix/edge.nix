# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Rendered by tofu from remote-infra/tofu/main.tf — do not hand-edit.
# The box gets its address via DHCP; customer /128s are bound at
# runtime by the edge's IPV6_FREEBIND listeners. PLACEHOLDER subnet —
# the real one is filled by tofu.
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
            # / is the btrfs top level; /nix is a separate subvolume.
            subvolumes = {
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

  # ── Self-networking ─────────────────────────────────────────────
  # The box gets its own address via DHCP — no baked NIC name, no
  # static IP, no gateway math. Customer /128s are bound at runtime
  # by the edge's IPV6_FREEBIND listeners; nothing per-customer lives
  # in this config.
  networking.useDHCP = true;

  # ── The merged edge: forwarder + control plane ──────────────────
  services.cococoir-edge = {
    enable = true;
    subnet = "2a01:4f9:c014:2c44::/64";
    wgSubnet = "10.10.0.0/24";
  };

  # ── WireGuard server ─────────────────────────────────────────────
  # The interface is static; PEERS are added at runtime by the control
  # plane (`wg set`), so signups need no config change. Private key is
  # scp'd in at provision time.
  networking.wireguard.interfaces.wg0 = {
    privateKeyFile = "/etc/wireguard/edge-private.key";
    listenPort = 51820;
    ips = ["10.10.0.1/24"];
  };

  # ── Firewall ─────────────────────────────────────────────────────
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [80 443 8081];
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
