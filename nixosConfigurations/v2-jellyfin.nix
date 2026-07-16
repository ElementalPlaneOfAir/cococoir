# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir v2 — manual VM: Jellyfin + Garage + Caddy.
#
# Run with:
#   nix run .#v2-jellyfin
#   # or headless:
#   nix run .#v2-jellyfin -- -nographic
#
# Then from your normal computer (the host):
#   curl --resolve jellyfin.local:4433:127.0.0.1 -k \
#        https://jellyfin.local:4433/health
#   # should return 200 with body "Healthy" (-k skips the cert
#   # check; the cert is self-signed and per-VM).
#
# To open in a browser, add `jellyfin.local` to your host's
# /etc/hosts:
#   sudo ./scripts/add-jellyfin-hosts.sh
#   sudo ./scripts/add-jellyfin-hosts.sh rm   # when done
# then visit https://jellyfin.local:4433 — your browser will
# warn about the self-signed cert; accept it (it's a dev VM,
# the cert is regenerated every build). You'll see Jellyfin's
# setup wizard. Configure an admin user, add /media/entertain
# as a library, and you'll see the pre-seeded welcome.txt.
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
    pkgs.runCommand "cococoir-v2-jellyfin-secrets" {
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

  # Build-time self-signed TLS cert for `jellyfin.local`. The
  # browser will warn about it (it's a dev VM, the cert changes
  # every build); -k on curl / "Accept the risk" in the browser
  # gets past it. In production, sops-nix + ACME replace this.
  testCerts = pkgs.runCommand "cococoir-v2-jellyfin-tls" {
    buildInputs = [pkgs.openssl];
  } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout $out/key.pem -out $out/cert.pem -days 365 \
      -subj "/CN=jellyfin.local" \
      -addext "subjectAltName=DNS:jellyfin.local,DNS:localhost" \
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
  networking.hostName = "v2-jellyfin";
  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443];
  };

  # Self-signed TLS cert for the Caddy vhost. Built at VM build
  # time and read at runtime. See `testCerts` above.
  environment.etc."cococoir-v2-jellyfin-tls".source = testCerts;

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
  environment.etc."cococoir-v2-jellyfin-secrets".source = testSecrets;

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
      rpcSecretFile = "/etc/cococoir-v2-jellyfin-secrets/rpc-secret";
      adminTokenFile = "/etc/cococoir-v2-jellyfin-secrets/admin-token";
      metricsTokenFile = "/etc/cococoir-v2-jellyfin-secrets/metrics-token";
      accessKeyIdFile = "/etc/cococoir-v2-jellyfin-secrets/access-key-id";
      secretAccessKeyFile = "/etc/cococoir-v2-jellyfin-secrets/secret-access-key";
    };
    buckets.media = {};
  };

  # Caddy: serves the Jellyfin vhost on :443 with the build-time
  # self-signed cert. The Caddy vhost-options module doesn't
  # expose a `tls` option, so we emit the `tls` directive via
  # `extraConfig`. Caddy listens on :443 for the vhost and on
  # :80 for the auto-redirect to https.
  #
  # The `email` option is left at its default (null) — Caddy
  # doesn't try ACME for `jellyfin.local` (no real DNS), and
  # setting `email = ""` is a parse error.
  services.caddy = {
    enable = true;
    virtualHosts."jellyfin.local".extraConfig = ''
      tls /etc/cococoir-v2-jellyfin-tls/cert.pem /etc/cococoir-v2-jellyfin-tls/key.pem
      reverse_proxy 127.0.0.1:8096
    '';
  };

  # Jellyfin service. `bucket` defaults to "media" (4-option
  # contract). Jellyfin's bucket + FUSE mount are auto-declared
  # under cococoir.storage.* by the service module.
  cococoir.services.jellyfin = {
    enable = true;
    domain = "jellyfin.local";
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
        This file was pre-seeded by the v2-jellyfin VM config.
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
