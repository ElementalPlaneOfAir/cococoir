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
#   curl --resolve jellyfin.local:8080:127.0.0.1 \
#        http://jellyfin.local:8080/health
#   # should return 200 with body "Healthy"
#
# To open in a browser, add to /etc/hosts (or equivalent):
#   127.0.0.1 jellyfin.local
# then visit http://jellyfin.local:8080 — you'll see Jellyfin's
# setup wizard. Configure an admin user, add /media/entertain as
# a library, and you'll see the pre-seeded welcome.txt.
#
# SSH in for inspection:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       root@localhost
#
# The VM is hermetic: secrets are generated at build time, Garage
# runs single-node, no sops-nix, no real network. Production
# uses sops-nix with the user's age key.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Static SSH host key. Without this, the nixpkgs openssh
  # module's default host keys are content-addressed to the
  # nix store and change whenever the activation derivation's
  # closure shifts (e.g. a config edit that changes the
  # activation's input set). That breaks the client's
  # known_hosts on every qcow2 rebuild. A fixed, committed
  # key gives a stable fingerprint for the lifetime of the
  # repo.
  #
  # The private key is checked in plaintext at
  # ./v2-jellyfin/ssh_host_ed25519_key. This is acceptable
  # because the v2-jellyfin VM is a single-tenant dev image
  # with no untrusted clients. Production hosts must generate
  # fresh host keys at install time, never reuse these.
  #
  # Fingerprint (verify on first connect):
  #   SHA256:VpWK7zm4jFW3R1YnvZR54ylYUJAugU1DoD5tApKapNc
  sshHostKeys =
    pkgs.runCommand "v2-jellyfin-ssh-host-keys" {} ''
      mkdir -p $out
      cp ${./v2-jellyfin/ssh_host_ed25519_key} $out/ssh_host_ed25519_key
      cp ${./v2-jellyfin/ssh_host_ed25519_key.pub} $out/ssh_host_ed25519_key.pub
      chmod 0600 $out/ssh_host_ed25519_key
      chmod 0644 $out/ssh_host_ed25519_key.pub
    '';

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
    hostKeys = [
      {
        type = "ed25519";
        path = "${sshHostKeys}/ssh_host_ed25519_key";
      }
    ];
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

  # Caddy: serves the Jellyfin vhost on :80. The email option
  # defaults to null and is only emitted into the Caddyfile when
  # non-null. Setting `email = ""` is a parse error: Caddy's
  # Caddyfile parser sees `email` followed by a line ending and
  # bails. For a dev VM, leave email unset (null) — Caddy won't
  # try ACME for `jellyfin.local`.
  services.caddy = {
    enable = true;
    virtualHosts."jellyfin.local".extraConfig = ''
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

  # QEMU port forward: host :8080 -> guest :80 (Caddy).
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 8080;
      guest.port = 80;
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
