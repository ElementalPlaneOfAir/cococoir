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
#   curl --resolve jellyfin.vmtest.local:4433:127.0.0.1 -k \
#        https://jellyfin.vmtest.local:4433/health
#   # should return 200 with body "Healthy" (-k skips the cert
#   # check; the cert is self-signed and per-VM).
#
# To open in a browser, add the per-service subdomains to your
# host's /etc/hosts:
#   sudo ./scripts/vmtest-hosts.sh
#   sudo ./scripts/vmtest-hosts.sh rm   # when done
# then visit https://jellyfin.vmtest.local:4433 — your browser
# will warn about the self-signed cert; accept it (it's a dev
# VM, the cert is regenerated every build). You'll see
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
# a real ACME certificate (see cococoir.tls.mode = "acme").
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  # Build-time secret generation, same pattern as the storage
  # nixosTest. In production, sops-nix writes these files with
  # mode 0440 / 0400 at /run/secrets/<name>; the cococoir.secrets
  # module wires that automatically when `cococoir.secrets.sopsFile`
  # is set. We keep the explicit `cococoir.storage.secrets.*File`
  # wiring here because vmtest does NOT use sops-nix.
  testSecrets =
    pkgs.runCommand "vmtest-secrets" {
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

  # Build-time pocket-id secrets. ENCRYPTION_KEY is the
  # base64-encoded 32-byte symmetric key pocket-id uses to
  # encrypt private keys + tokens at rest. The file MUST NOT
  # have a trailing newline — pocket-id treats CR/LF as
  # part of the key, so a stray \n fails decryption on
  # restart. STATIC_API_KEY auto-creates a "Static API
  # User" admin on first boot, so we can administer
  # pocket-id via its API without clicking through the
  # setup wizard.
  testPocketidSecrets =
    pkgs.runCommand "vmtest-pocketid-secrets" {
      buildInputs = [pkgs.openssl];
    } ''
      mkdir -p $out
      # `openssl rand -base64` adds a trailing newline; strip
      # it with `tr -d '\n'` + `printf '%s'`. Both files must
      # be exactly the bytes pocket-id expects — no CR/LF.
      openssl rand -base64 32 | tr -d '\n' > $out/encryption-key
      api_key="$(openssl rand -base64 32 | tr -d '\n')"
      printf '%s' "$api_key" > $out/static-api-key
      chmod 0400 $out/encryption-key $out/static-api-key
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
    "127.0.0.1" = ["pocketid.vmtest.local" "jellyfin.vmtest.local"];
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

  # Build-time secrets mounted at well-known paths. Production
  # would use `cococoir.secrets.sopsFile = ./secrets.yaml` instead.
  environment.etc = {
    "vmtest-tls".source = testCerts;
    "vmtest-secrets".source = testSecrets;
    "vmtest-pocketid-secrets".source = testPocketidSecrets;
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

  # Storage layer. cococoir.storage.enable defaults to true
  # (always-on). The `secrets` block sets the 5 secret file
  # paths; production wires these from sops-nix. Single-node
  # ports are hardcoded — no cluster config needed.
  cococoir.storage.secrets = {
      rpcSecretFile = "/etc/vmtest-secrets/rpc-secret";
      adminTokenFile = "/etc/vmtest-secrets/admin-token";
      metricsTokenFile = "/etc/vmtest-secrets/metrics-token";
      accessKeyIdFile = "/etc/vmtest-secrets/access-key-id";
      secretAccessKeyFile = "/etc/vmtest-secrets/secret-access-key";
    };
  cococoir.storage.buckets.media = {};

  # Caddy: just enable. Every cococoir.services.<name> with
  # enable = true registers a vhost via the contract factory,
  # which pulls `tls` from cococoir.tls and `reverse_proxy` /
  # 403 from `public`. No per-vhost boilerplate here.
  #
  # The `email` option is left at its default (null) — Caddy
  # doesn't try ACME for `*.vmtest.local` (no real DNS), and
  # `email = ""` is a parse error.
  services.caddy.enable = true;

  # Jellyfin service. The factory's `defaultBucket = "media"`
  # auto-declares the bucket + FUSE mount under
  # cococoir.storage.*. Domain defaults to `jellyfin.vmtest.local`
  # via cococoir.baseDomain.
  cococoir.services.jellyfin = {
    enable = true;
    public = true;
  };

  # OIDC RBAC plugin (jellyfin-plugin-oidc v1.0.8 from Ezeqielle)
  # for PocketID SSO. The plugin is downloaded at build time and
  # symlinked into /var/lib/jellyfin/plugins/OIDC RBAC/ at
  # Jellyfin startup. Configuration (provider, client secret,
  # role mappings) is applied by the cococoir-jellyfin-oidc
  # oneshot via Jellyfin's REST API — no raw XML.
  systemd.services.jellyfin.preStart = let
    oidcPlugin = pkgs.callPackage ../nix/packages/jellyfin-plugin-oidc.nix {};
  in
  lib.mkBefore ''
    mkdir -p /var/lib/jellyfin/plugins/"OIDC RBAC"
    rm -f /var/lib/jellyfin/plugins/"OIDC RBAC"/*.dll
    ln -sf ${oidcPlugin}/* /var/lib/jellyfin/plugins/"OIDC RBAC"/
    chmod -R 770 /var/lib/jellyfin/plugins/"OIDC RBAC"
  '';

  # Pocket-ID: self-hosted OIDC provider, always-on (the
  # platform requires OIDC). Domain defaults to
  # `auth.vmtest.local` via cococoir.baseDomain +
  # conventionalSubdomain = "auth"; we override to
  # `pocketid.vmtest.local` to keep URLs stable with the
  # prior vmtest (and the bookmarks the user has built up).
  cococoir.services.pocketid = {
    domain = "pocketid.vmtest.local";
    public = true;
    encryptionKeyFile = "/etc/vmtest-pocketid-secrets/encryption-key";
    staticApiKeyFile = "/etc/vmtest-pocketid-secrets/static-api-key";
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
