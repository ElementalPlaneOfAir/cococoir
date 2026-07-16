# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir v2 — manual dev VM ("vmtest"). One VM hosts every
# cococoir service under test, each behind its own Caddy vhost.
# Today that's Jellyfin; nextcloud/gitea/etc. land here as the
# service modules come online.
#
# Public names use the `cococoir-vmtest.local` cookie-jar so the
# VM can route by hostname. The wildcard cert SAN covers the
# whole jar.
#
# Run with:
#   nix run .#vmtest
#   # or headless:
#   nix run .#vmtest -- -nographic
#
# Then from your normal computer (the host):
#   curl --resolve jellyfin.cococoir-vmtest.local:4433:127.0.0.1 -k \
#        https://jellyfin.cococoir-vmtest.local:4433/health
#   # should return 200 with body "Healthy" (-k skips the cert
#   # check; the cert is self-signed and per-VM).
#
# To open in a browser, add the per-service subdomains to your
# host's /etc/hosts:
#   sudo ./scripts/cococoir-vmtest-hosts.sh
#   sudo ./scripts/cococoir-vmtest-hosts.sh rm   # when done
# then visit https://jellyfin.cococoir-vmtest.local:4433 — your
# browser will warn about the self-signed cert; accept it (it's
# a dev VM, the cert is regenerated every build). You'll see
# Jellyfin's setup wizard. Configure an admin user, add
# /media/entertain as a library, and you'll see the pre-seeded
# welcome.txt.
#
# On NixOS hosts /etc/hosts is read-only; the script will tell
# you to add `networking.hosts` to your NixOS config instead.
#
# SSH in for inspection:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       root@localhost
#
# The VM is hermetic: secrets and the TLS cert are generated at
# build time, Garage runs single-node, no sops-nix, no real
# network. Production uses sops-nix with the user's age key and
# a real ACME certificate.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Build-time secret generation, same pattern as the storage
  # nixosTest. In production, sops-nix writes these files with
  # mode 0440 / 0400 at /run/secrets/<name>.
  testSecrets =
    pkgs.runCommand "cococoir-vmtest-secrets" {
      buildInputs = [pkgs.openssl pkgs.gnused];
    } ''
      mkdir -p $out
      openssl rand -hex -out $out/rpc-secret 32
      openssl rand -hex -out $out/admin-token 32
      openssl rand -hex -out $out/metrics-token 32
      printf 'GK%s' "$(openssl rand -hex 12)" > $out/access-key-id
      openssl rand -hex -out $out/secret-access-key 32
      chmod 0440 $out/access-key-id $out/secret-access-key
      chmod 0400 $out/rpc-secret $out/admin-token $out/metrics-token
    '';

  # Build-time self-signed TLS cert for the
  # `*.cococoir-vmtest.local` cookie-jar. The browser will warn
  # about it (it's a dev VM, the cert changes every build);
  # -k on curl / "Accept the risk" in the browser gets past it.
  # Caddy matches the longest host first, so future per-service
  # vhosts just work without touching the cert. In production,
  # sops-nix + ACME replace this.
  testCerts = pkgs.runCommand "cococoir-vmtest-tls" {
    buildInputs = [pkgs.openssl];
  } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout $out/key.pem -out $out/cert.pem -days 365 \
      -subj "/CN=*.cococoir-vmtest.local" \
      -addext "subjectAltName=DNS:cococoir-vmtest.local,DNS:*.cococoir-vmtest.local" \
      >/dev/null 2>&1
    chmod 0444 $out/cert.pem
    chmod 0400 $out/key.pem
  '';

  # NOTE: in modern nixpkgs (>= 25.05), `nixpkgs.lib.nixosSystem`
  # only includes nixos/modules/virtualisation/qemu-vm.nix in a
  # `vmVariant` submodule, not the main config. So options like
  # `virtualisation.forwardPorts` are not declared here. The
  # flake.nix imports qemu-vm.nix directly to declare them.
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

  # Self-signed TLS cert for the Caddy vhost. Built at VM build
  # time and read at runtime. See `testCerts` above.
  environment.etc."cococoir-vmtest-tls".source = testCerts;

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
    kitty # So the system has support for my terminal outputs
  ];

  programs.fish.enable = true;

  # Storage layer: Garage single-node, one bucket, FUSE mount.
  # Secrets are the build-time generated ones; sops-nix would
  # replace them with /run/secrets/<name> paths in production.
  environment.etc."cococoir-vmtest-secrets".source = testSecrets;

  cococoir.storage = {
    enable = true;
    cluster = {
      rpcBindAddr = "127.0.0.1:3901";
      rpcPublicAddr = "127.0.0.1:3901";
      s3ApiBindAddr = "127.0.0.1:3900";
      adminApiBindAddr = "127.0.0.1:3903";
      region = "garage";
    };
    node = {
      id = "node-1";
      address = "127.0.0.1:3901";
      zone = "z1";
      capacity = "1T";
    };
    secrets = {
      rpcSecretFile = "/etc/cococoir-vmtest-secrets/rpc-secret";
      adminTokenFile = "/etc/cococoir-vmtest-secrets/admin-token";
      metricsTokenFile = "/etc/cococoir-vmtest-secrets/metrics-token";
      accessKeyIdFile = "/etc/cococoir-vmtest-secrets/access-key-id";
      secretAccessKeyFile = "/etc/cococoir-vmtest-secrets/secret-access-key";
    };
    buckets.media = {};
  };

  # Caddy: serves the Jellyfin vhost on :443 with the build-time
  # self-signed wildcard cert. The Caddy vhost-options module
  # doesn't expose a `tls` option, so we emit the `tls` directive
  # via `extraConfig`. Caddy listens on :443 for the vhost and
  # on :80 for the auto-redirect to https.
  #
  # Future services (nextcloud, gitea, ...) get their own vhost
  # block here with `reverse_proxy 127.0.0.1:<port>`. The
  # wildcard cert SAN covers them all.
  #
  # The `email` option is left at its default (null) — Caddy
  # doesn't try ACME for `*.cococoir-vmtest.local` (no real
  # DNS), and setting `email = ""` is a parse error.
  services.caddy = {
    enable = true;
    virtualHosts."jellyfin.cococoir-vmtest.local".extraConfig = ''
      tls /etc/cococoir-vmtest-tls/cert.pem /etc/cococoir-vmtest-tls/key.pem
      reverse_proxy 127.0.0.1:8096
    '';
  };

  # Jellyfin service. `bucket` defaults to "media" (4-option
  # contract). Jellyfin's bucket + FUSE mount are auto-declared
  # under cococoir.storage.* by the service module. The domain
  # lives in the `cococoir-vmtest.local` cookie-jar so the
  # wildcard cert covers it.
  cococoir.services.jellyfin = {
    enable = true;
    domain = "jellyfin.cococoir-vmtest.local";
    public = true;
  };

  # Jellyfin's StorageHelper.TestDataDirectorySize checks
  # /var/lib/jellyfin/data has >= 2GiB free at startup and aborts
  # with System.InvalidOperationException otherwise. The default
  # nixpkgs qemu-vm disk is 1024MB, which leaves /var with ~887MB
  # free — not enough. Bump the disk to give /var room.
  virtualisation.diskSize = 10240; # 10 GiB, in MB

  # Pre-seed the FUSE mount with a test file. The oneshot waits
  # for cococoir-fuse-media.service to be up before writing, so
  # the welcome.txt appears in the bucket at /media/entertain
  # before Jellyfin starts scanning for libraries.
  #
  # NB: `writeShellApplication` returns a *package* (a directory
  # with `bin/<name>` inside), so `ExecStart = pkg` is "Is a
  # directory". `writeShellScript` returns a single file, which is
  # what ExecStart wants.
  systemd.services.cococoir-pre-seed-media = {
    description = "Pre-seed the media bucket with a test file";
    wantedBy = ["multi-user.target"];
    after = ["cococoir-fuse-media.service"];
    requires = ["cococoir-fuse-media.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pre-seed-media" ''
        cat > /media/entertain/welcome.txt <<'EOF'
        Hello from cococoir v2!
        This file was pre-seeded by the cococoir vmtest VM config.
        The v2 single-machine stack (Garage S3 + FUSE mount + Jellyfin + Caddy)
        served it to you across the QEMU port forward.
        EOF
      '';
    };
  };

  # QEMU port forwards:
  #   host :4433 -> guest :443  (Caddy, TLS)
  #   host :2222 -> guest :22   (SSH)
  # 4433 (not 443) on the host so we don't need root to bind.
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 4433;
      guest.port = 443;
    }
    {
      from = "host";
      host.port = 2222;
      guest.port = 22;
    }
  ];

  # Disable the cococoir-edge / cococoir-client systemd units for
  # the v2 single-machine path. The forwarder is a no-op until a
  # WireGuard peer is configured, and the systemd units are
  # conditional on forwards being non-empty (per client.nix).
  # This is the v2 default.
}
