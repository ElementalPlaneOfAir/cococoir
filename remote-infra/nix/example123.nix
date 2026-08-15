# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Rendered by tofu from remote-infra/tofu/main.tf — do not hand-edit.
# The customer box is the home machine (behind CG-NAT, no public
# IPv6): the full v2 product plus a WireGuard DIAL-OUT to the edge
# and cococoir-client forwarding the tunnel's :80/:443 to local
# Caddy. Caddy terminates TLS with real ACME certs obtained through
# the tunnel (blind forwarding).
#
# FILL IN (operator, after render):
#   cococoir.storage.btrfs.pool.devices — this box's real disks
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

    storage.btrfs.pool.devices = [
      # FILL IN: this box's real disks (e.g. /dev/disk/by-id/...)
    ];
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
        publicKey = "GHJgVwwXSM4At4D4EERb8Q4G+1mzg1YCBWDGNEArwxg=";
        endpoint = "62.238.111.21:51820";
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
