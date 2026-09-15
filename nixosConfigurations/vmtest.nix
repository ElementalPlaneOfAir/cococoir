# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress v2 — manual dev VM ("vmtest"). One VM hosts every
# fortress service under test, each behind its own Caddy vhost.
# Each service gets a subdomain of `vmtest.local` so the
# wildcard cert covers the whole jar.
#
# Platform-specific bits only — the shared demo tier (services,
# certs, secrets, customer config) lives in demo-base.nix.
#
# Run with:
#   nix run .#vmtest
#   # or headless:
#   nix run .#vmtest -- -nographic
#
# Then from your normal computer (the host):
#   curl -k https://jellyfin.vmtest.local/health
#   # should return 200 with body "Healthy" (-k skips the cert
#   # check; the cert is self-signed and per-VM).
#   curl -k https://auth.vmtest.local/dex/.well-known/openid-configuration
#   # should return json (OIDC discovery document)
#
# To open in a browser, add the per-service subdomains to your
# host's /etc/hosts:
#   127.0.0.1 jellyfin.vmtest.local auth.vmtest.local
# then visit https://jellyfin.vmtest.local — your browser
# will warn about the self-signed cert; accept it. You'll see
# the Jellyfin login page with a "Sign in with Dex" button
# below the password fields. Dex auto-creates users via
# OIDC on first login.
#
# On NixOS hosts /etc/hosts is read-only; the script will tell
# you to add `networking.hosts` to your NixOS config instead.
#
# SSH in for inspection:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       root@localhost
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [./demo-base.nix];

  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443];
  };

  # Real NixOS VM config. Grub on /dev/vda, ext4 root. Same pattern
  # as the v0 single-tenant test config.
  boot.loader.grub.enable = true;
  boot.loader.grub.devices = ["/dev/vda"];
  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
  };

  # SSH for the manual loop. The VM auto-injects no SSH key, so
  # the user logs in as root with an empty password. nixosTest
  # doesn't need this.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };
  users.users.root.password = "password";
  environment.systemPackages = with pkgs; [
    btop
    kitty
    python3
    curl
    jq
    # vmtest-bootstrap.sh verifies every vhost cert with s_client.
    openssl
    # vmtest-bootstrap.sh asserts the LAN DNS plane (dig against the
    # box's dnsmasq).
    dnsutils
  ];

  programs.fish.enable = true;

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
  };

  # btrfs pool. fortress.storage.enable defaults to true
  # (always-on). Two virtual virtio drives (2 GiB each) form
  # a btrfs RAID1 pool. The jellyfin and cryptpad service modules
  # auto-declare their subvolumes.
  fortress.storage.btrfs.pool.devices = ["/dev/vdb" "/dev/vdc"];

  # LAN access plane (ADR-028): QEMU user-mode networking assigns
  # the guest 10.0.2.15 deterministically, so vmtest exercises the
  # real customer path — dnsmasq answers the service domains with
  # the LAN address, Caddy binds it, and vmtest-bootstrap.sh
  # resolves + connects + verifies the cert exactly as a LAN device
  # would. Production sets the box's DHCP-reserved address here.
  fortress.network.lanAddress = "10.0.2.15";

  # Jellyfin's StorageHelper.TestDataDirectorySize checks
  # /var/lib/jellyfin/data has >= 2GiB free at startup and aborts
  # with System.InvalidOperationException otherwise. The default
  # nixpkgs qemu-vm disk is 1024MB, which leaves /var with ~887MB
  # free — not enough. Bump the disk to give /var room.
  virtualisation.diskSize = 10240; # 10 GiB, in MB
  virtualisation.emptyDiskImages = [2048 2048]; # 2 x 2 GiB for btrfs pool
  # The full stack (jellyfin + dex + seerr + radarr + sonarr +
  # qbittorrent + cryptpad + caddy) OOM-kills jellyfin on the 1GB
  # default, which wedges the media-apply pipeline. 4GiB holds all
  # of it with headroom.
  virtualisation.memorySize = 4096; # MiB

  # Pre-seed the btrfs subvolume with a test file. The oneshot waits
  # for fortress-btrfs-subvolumes.service before writing.
  systemd.services.fortress-pre-seed-media = {
    description = "Pre-seed the jellyfin subvolume with a test file";
    wantedBy = ["multi-user.target"];
    after = ["fortress-btrfs-subvolumes.service"];
    requires = ["fortress-btrfs-subvolumes.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pre-seed-media" ''
        cat > /data/media/movies/welcome.txt <<'EOF'
        Hello from fortress v2!
        This file was pre-seeded by the fortress vmtest VM config.
        The v2 single-machine stack (btrfs pool + Jellyfin + Caddy)
        served it to you across the QEMU port forward.
        EOF
      '';
    };
  };

  # QEMU port forwards:
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 443;
      guest.port = 443;
    }
    {
      from = "host";
      host.port = 2222;
      guest.port = 22;
    }
  ];
}
