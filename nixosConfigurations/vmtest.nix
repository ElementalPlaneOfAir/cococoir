# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir v2 — manual dev VM ("vmtest"). One VM hosts every
# cococoir service under test, each behind its own Caddy vhost.
# Each service gets a subdomain of `vmtest.local` so the
# wildcard cert covers the whole jar.
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
# below the password fields. PocketID auto-creates users via
# OIDC on first login.
#
# On NixOS hosts /etc/hosts is read-only; the script will tell
# you to add `networking.hosts` to your NixOS config instead.
#
# SSH in for inspection:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       root@localhost
#
# The VM is hermetic: secrets and the TLS cert are generated at
# build time, ZFS pool runs with two virtual disks, no sops-nix,
# no real network. Production uses sops-nix with the user's age key and
# a real ACME certificate (see cococoir.tls.mode = "acme").
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  # Build-time secret generation for the manual VM. In
  # production, sops-nix writes these files with mode 0440 /
  # 0400 at /run/secrets/<name>. We keep explicit wiring here
  # because vmtest does NOT use sops-nix.

  # Build-time empty disk images for the ZFS pool (2 × 2 GiB).
  # The VM's root is on /dev/vda (ext4); these appear as
  # /dev/vdb and /dev/vdc (virtio drives in order).
  zfsVirtualDisks =
    pkgs.runCommand "vmtest-zfs-disks" {
      nativeBuildInputs = [ pkgs.qemu ];
    } ''
      mkdir -p $out
      qemu-img create -f raw "$out/disk1.img" 2G >/dev/null
      qemu-img create -f raw "$out/disk2.img" 2G >/dev/null
    '';

  # Build-time Dex secrets: OIDC client secret for Jellyfin
  # and a bcrypt password hash for the test admin user.
  # Dex's replace-secret reads the client secret file at
  # startup and substitutes its path in the YAML config with
  # the file content. The bcrypt hash goes into Dex's
  # staticPasswords.
  testDexSecrets =
    pkgs.runCommand "vmtest-dex-secrets" {
      buildInputs = [pkgs.openssl pkgs.apacheHttpd];
    } ''
      mkdir -p $out
      openssl rand -hex -out $out/jellyfin-client-secret 32
      openssl rand -hex -out $out/cryptpad-client-secret 32
      chmod 0440 $out/jellyfin-client-secret $out/cryptpad-client-secret
      htpasswd -bnBC 10 "" password | cut -d: -f2 | tr -d '\n' > $out/admin-password-hash
    '';

  # Build-time self-signed TLS cert for the
  # `*.vmtest.local` cookie-jar. The browser will warn
  # about it (it's a dev VM, the cert changes every build);
  # -k on curl / "Accept the risk" in the browser gets past it.
  # In production, `cococoir.tls.mode = "acme"` makes Caddy
  # issue a real cert.
  testCerts =
    pkgs.runCommand "vmtest-tls" {
      buildInputs = [pkgs.openssl];
    } ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout $out/key.pem -out $out/cert.pem -days 365 \
        -subj "/CN=*.vmtest.local" \
        -addext "subjectAltName=DNS:vmtest.local,DNS:*.vmtest.local" \
        >/dev/null 2>&1
      chmod 0444 $out/cert.pem
      chmod 0400 $out/key.pem
    '';
in {
  imports = [
    (import ../nix/nixos-modules)
  ];

  system.stateVersion = "25.11";
  networking.hostName = "vmtest";
  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443];
  };

  networking.hosts = {
    "127.0.0.1" = ["auth.vmtest.local" "jellyfin.vmtest.local" "cryptpad.vmtest.local"
                      "radarr.vmtest.local" "sonarr.vmtest.local" "lidarr.vmtest.local" "prowlarr.vmtest.local"];
  };

  security.pki.certificates = [
    (builtins.readFile "${testCerts}/cert.pem")
  ];

  # Platform-wide config. baseDomain + tls.mode do the work that
  # used to live in every per-vhost `extraConfig`:
  #   - service `domain` options default to `<svc>.vmtest.local`
  #     (override per-service if you need a non-conventional name)
  #   - Caddy's `tls` directive is emitted automatically from
  #     `cococoir.tls.{certFile, keyFile}` for every vhost
  #   - `services.caddy.enable = true` and the per-service
  #     `cococoir.services.<name>.enable = true` together drive
  #     vhost creation via the contract factory
  cococoir = {
    baseDomain = "vmtest.local";
    tls = {
      mode = "self-signed";
      certFile = "/etc/vmtest-tls/cert.pem";
      keyFile = "/etc/vmtest-tls/key.pem";
    };
  };

  # Build-time secrets mounted at well-known paths.
  environment.etc = {
    "vmtest-tls".source = testCerts;
    "vmtest-dex-secrets".source = testDexSecrets;
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
  ];

  programs.fish.enable = true;

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
  };

  # ZFS pool. cococoir.storage.enable defaults to true
  # (always-on). Two virtual virtio drives (2 GiB each) form
  # a mirror pool. The jellyfin and cryptpad service modules
  # auto-declare their ZFS datasets.
  cococoir.storage.zfs.pool.devices = ["/dev/vdb" "/dev/vdc"];

  # Caddy: just enable. Every cococoir.services.<name> with
  # enable = true registers a vhost via the contract factory,
  # which pulls `tls` from cococoir.tls and `reverse_proxy` /
  # 403 from `public`. No per-vhost boilerplate here.
  #
  # The `email` option is left at its default (null) — Caddy
  # doesn't try ACME for `*.vmtest.local` (no real DNS), and
  # `email = ""` is a parse error.
  services.caddy.enable = true;

  # Jellyfin service. Domain defaults to jellyfin.vmtest.local
  # via cococoir.baseDomain. Datasets auto-declared by the
  # jellyfin module.
  cococoir.services.jellyfin = {
    enable = true;
    public = true;
  };

  cococoir.services.cryptpad = {
    enable = true;
    public = true;
  };

  cococoir.services.radarr = {
    enable = true;
    public = false;
  };
  cococoir.services.sonarr = {
    enable = true;
    public = false;
  };
  cococoir.services.lidarr = {
    enable = true;
    public = false;
  };
  cococoir.services.prowlarr = {
    enable = true;
    public = false;
  };

  # Dex: self-hosted OIDC provider with email+password auth.
  # Domain defaults to auth.vmtest.local via cococoir.baseDomain.
  # Users are declared in staticPasswords — no setup wizard, no
  # API provisioning. Groups flow through the `groups` OIDC scope
  # so Jellyfin picks them up as role claims.
  cococoir.services.dex = {
    public = true;
  };

  # Build-time secret files wired into Dex and jellarr.
  # The generated Jellyfin client secret lives in
  # /etc/dex/clients/jellyfin-secret; the cococoir-jellyfin-oidc-secret
  # oneshot copies it there on first boot (idempotent within a VM
  # overlay). The bcrypt hash goes directly into staticPasswords.
  services.dex.settings = {
    staticClients = [{
      id = "vmtest-cli";
      public = true;
      name = "vmtest CLI";
    }];

    staticPasswords = let
      hash = builtins.readFile "${testDexSecrets}/admin-password-hash";
    in [{
      email = "admin@example.com";
      hash = hash;
      username = "admin";
      userID = "08a8684b-db88-4b73-90a9-3cd1661f5466";
      groups = ["admins"];
      preferredUsername = "admin";
    }];
  };

  environment.etc."dex/clients/jellyfin-secret".source =
    "${testDexSecrets}/jellyfin-client-secret";

  environment.etc."dex/clients/cryptpad-secret".source =
    "${testDexSecrets}/cryptpad-client-secret";

  # Jellarr libraries for vmtest. Plain definitions merge with the
  # cococoir modules: this overrides the jellyfin module's mkDefault
  # virtualFolders, and the jellyfin-oidc integration's `plugins` /
  # `branding` merge in alongside. Do NOT wrap this in lib.mkForce —
  # mkForce on a submodule silently discards the OIDC plugin config.
  services.jellarr.config = {
    library.virtualFolders = [
      {
        name = "Movies";
        collectionType = "movies";
        libraryOptions.pathInfos = [{ path = "/data/media/movies"; }];
      }
      {
        name = "TV Shows";
        collectionType = "tvshows";
        libraryOptions.pathInfos = [{ path = "/data/media/shows"; }];
      }
      {
        name = "Music";
        collectionType = "music";
        libraryOptions.pathInfos = [{ path = "/data/media/music"; }];
      }
    ];
  };

  # Jellyfin's StorageHelper.TestDataDirectorySize checks
  # /var/lib/jellyfin/data has >= 2GiB free at startup and aborts
  # with System.InvalidOperationException otherwise. The default
  # nixpkgs qemu-vm disk is 1024MB, which leaves /var with ~887MB
  # free — not enough. Bump the disk to give /var room.
  virtualisation.diskSize = 10240; # 10 GiB, in MB

  virtualisation.qemu.options = [
    "-drive file=${zfsVirtualDisks}/disk1.img,format=raw,if=virtio"
    "-drive file=${zfsVirtualDisks}/disk2.img,format=raw,if=virtio"
  ];

  # Pre-seed the ZFS dataset with a test file. The oneshot waits
  # for cococoir-zfs-datasets.service before writing.
  systemd.services.cococoir-pre-seed-media = {
    description = "Pre-seed the jellyfin dataset with a test file";
    wantedBy = ["multi-user.target"];
    after = ["cococoir-zfs-datasets.service"];
    requires = ["cococoir-zfs-datasets.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pre-seed-media" ''
        cat > /data/media/movies/welcome.txt <<'EOF'
        Hello from cococoir v2!
        This file was pre-seeded by the cococoir vmtest VM config.
        The v2 single-machine stack (ZFS pool + Jellyfin + Caddy)
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
