# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Customer box NixOS config — PLACEHOLDER values.
#
# This file is overwritten by `tofu apply` (remote-infra/tofu/render.tf
# renders templates/example123.nix.tftpl into this path). The
# placeholders below let the flake evaluate before provisioning. Do
# not hand-edit the rendered values; edit the template instead.
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    (import ../nix/nixos-modules)
  ];

  system.stateVersion = "25.11";
  networking.hostName = "example123";

  cococoir = {
    baseDomain = "example123.interdim.net";
    tls.mode = "acme"; # real certs through the tunnel

    services = {
      jellyfin.public = true;
      cryptpad.public = true;
      radarr.public = false;
      sonarr.public = false;
      lidarr.public = false;
      prowlarr.public = false;
      dex.public = true;
    };

    # Filled by the operator: this box's real disks.
    storage.btrfs.pool.devices = [];
  };

  services.caddy.enable = true;

  # ── Tunnel client half ───────────────────────────────────────────
  services.cococoir-client.enable = true;
  environment.etc."cococoir-client.json".text = builtins.toJSON {
    forwards = [
      {
        listen_addr = "10.10.0.2:80";
        proto = "tcp";
        dest_addr = "127.0.0.1:80";
      }
      {
        listen_addr = "10.10.0.2:443";
        proto = "tcp";
        dest_addr = "127.0.0.1:443";
      }
    ];
  };

  networking.wireguard.interfaces.wg0 = {
    privateKeyFile = "/etc/wireguard/example123-private.key";
    ips = ["10.10.0.2/24"];
    peers = [
      {
        publicKey = "CHANGE_ME_EDGE_WG_PUBKEY";
        endpoint = "1.2.3.4:51820"; # edge box IPv4 (filled by tofu)
        allowedIPs = ["10.10.0.1/32"];
        persistentKeepalive = 25; # keep the tunnel alive through NAT
      }
    ];
  };

  # ── IPv4 LAN path: the "custom DNS server" from the vision. ─────
  networking.hosts = {
    "127.0.0.1" = [
      "jellyfin.example123.interdim.net"
      "auth.example123.interdim.net"
      "cryptpad.example123.interdim.net"
    ];
  };

  networking.firewall.enable = true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtpDAeIfLOlZE5y/SaHQ8h60nqbPSWdStRsvux6ECbk nicole@vermissian"
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
}
