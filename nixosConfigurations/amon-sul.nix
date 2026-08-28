# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir v2 — amon-sul, the first real customer box.
#
# Deployed via the edge signup flow (username "fractal"): the box is
# reachable at `*.fractal.interdim.net`. Caddy terminates real ACME
# certs obtained through the WireGuard tunnel to the edge.
#
# Storage reuses the existing 14.6T btrfs in place — the pool mounts
# /media by LABEL `tank` (relabel the existing fs at deploy) and the
# jellyfin media subvolumes point at the existing /media/entertain/*
# dirs. Single drive, layout stripe (no redundancy, per ADR-023's
# documented single-drive posture).
#
# Desktop stripped (headless). Torrenting dropped. Non-catalog services
# (matrix, mautrix-gmessages, minecraft) are userland modules in
# ./amon-sul/custom/ per ADR-027.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./amon-sul/hardware-configuration.nix
    (import ../nix/nixos-modules)
    inputs.jellarr.nixosModules.default
    inputs.sops-nix.nixosModules.sops
    ./amon-sul/custom/matrix.nix
    ./amon-sul/custom/mautrix-gmessages.nix
    ./amon-sul/custom/minecraft.nix
    ./amon-sul/custom/gdoc-extract.nix
  ];

  system.stateVersion = "24.11";
  networking.hostName = "amon-sul";
  environment.systemPackages = with pkgs; [
    git
    fish
  ];
  services.tailscale.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Fully static networking: override hardware-config's
  # `useDHCP = mkDefault true`. Under global DHCP mode dhcpcd manages
  # /etc/resolv.conf and, since this interface never leases, it drops
  # the explicit nameservers (resolv.conf came up with `options edns0`
  # and no `nameserver` lines → DNS dead). Static config → static path.
  networking.useDHCP = false;
  networking.interfaces.enp11s0 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.0.7";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.0.1";
  networking.nameservers = ["8.8.8.8" "1.1.1.1"];

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [22 80 443];

  services.openssh.enable = true;

  users.users.nicole = {
    isNormalUser = true;
    extraGroups = ["wheel" "jellyfin"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtpDAeIfLOlZE5y/SaHQ8h60nqbPSWdStRsvux6ECbk nicole@vermissian"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoMeFDsyCKC9zi/8CdC5AcL467TYRQllrzrWOCutYHY nicole@vermissian"
    ];
  };
  users.users.brad = {
    isNormalUser = true;
    extraGroups = ["jellyfin"];
  };
  users.users.matthewkrumlauf = {
    isNormalUser = true;
  };

  cococoir = {
    baseDomain = "fractal.interdim.net";
    tls.mode = "acme";

    services = {
      jellyfin = {
        enable = true;
        public = true;
      };
      cryptpad = {
        enable = true;
        public = true;
      };
      dex.public = true;
    };

    storage.btrfs.pool = {
      devices = ["/dev/sda1"];
      layout = "stripe";
      mountpoint = "/media";
      name = "tank";
    };
  };

  # The existing media lives at /media/entertain/* (not the v2 default
  # <pool>/media/*). One override; jellarr, subvolumes, and mount
  # ordering all derive from it.
  cococoir.services.jellyfin.mediaRoot = "/media/entertain";

  services.caddy.enable = true;

  # Dex users (the OIDC accounts jellyfin/cryptpad authenticate via).
  # bcrypt hashes are filled at deploy time (replaced, not committed).
  services.dex.settings.staticPasswords = [
    {
      email = "nicole@fractal.interdim.net";
      hash = "$2b$10$ab2woi0QuI5sczAk3Wg1EOtdh9DgGQjUF9YyKhKIBu9UOmn1G0Dmu";
      username = "nicole";
      userID = "00000000-0000-0000-0000-000000000001";
      groups = ["admins"];
    }
    {
      email = "brad@fractal.interdim.net";
      hash = "$2b$10$lBlef1v6je65.nf8h5kud..ChUot1RV1EMAVVdlBHQ.bhSqID5A0y";
      username = "brad";
      userID = "00000000-0000-0000-0000-000000000002";
      groups = ["users"];
    }
  ];

  # ── Tunnel client half (client-owned, ADR-025) ──────────────────
  services.cococoir-client.enable = true;
  # Dashboard admin login (the box's control plane). The bcrypt hash of
  # AMON_SUL_MASTER_PASSWORD lives in /etc/cococoir-admin.env (0600,
  # written at deploy), NOT in the nix store. Fail-closed: the unit stops
  # rather than run the dashboard with no auth.
  services.cococoir-client.adminPasswordEnvFile = "/etc/cococoir-admin.env";
  environment.etc."cococoir-client.json".text = builtins.toJSON {
    # The client owns wg0: it generates + persists its own WG keypair
    # (/var/lib/cococoir/wg-private.key), brings the tunnel up from this
    # stable config, then the forwarder binds the tunnel IP. There is no
    # operator key-file step and no NixOS wireguard module. The tunnel
    # comes up once the client's public key is registered on the edge
    # (one authenticated /signup rotation at provision time).
    tunnel = {
      ip = "10.10.0.3";
      prefix = 24;
      # The edge's WG public key (GET /pubkey).
      edge_pubkey = "lX+5lGEF1qDJEag13Kymyxy/SJH63LPxKTvMg50WE2E=";
      # Dial-out to the edge over the public internet.
      edge_endpoint = "62.238.111.21:51820";
      # Route the edge's tunnel range over wg0.
      edge_allowed_ips = "10.10.0.0/24";
    };
    forwards = [
      {
        listen_addr = "10.10.0.3:80";
        proto = "tcp";
        dest_addr = "127.0.0.1:80";
      }
      {
        listen_addr = "10.10.0.3:443";
        proto = "tcp";
        dest_addr = "127.0.0.1:443";
      }
    ];
  };

  networking.hosts = {
    "127.0.0.1" = [
      "jellyfin.fractal.interdim.net"
      "auth.fractal.interdim.net"
      "cryptpad.fractal.interdim.net"
      "matrix.fractal.interdim.net"
    ];
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];
}
