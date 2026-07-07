# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/auth/pocketid — PocketID OIDC provider (base-layer auth).
#
# PocketID is the OIDC provider for the rest of the cococoir services
# (Jellyfin, Jellyseerr, Synapse, etc.). It is always enabled when
# cococoir is imported — users configure `cococoir.auth.pocketid.*`
# (domain, public, signupMode) but never an `enable` toggle. This
# mirrors the model for cococoir/garage: the user configures a
# deployment, not a per-service opt-in.
#
# This module:
#   1. Declares `cococoir.auth.pocketid.{domain,public,signupMode}`.
#   2. Enables `services.pocket-id` from nixpkgs (the upstream
#      NixOS module for PocketID, a thin wrapper around the
#      `pocket-id` package).
#   3. Runs `pocket-id-secret-init.service` (a oneshot) BEFORE
#      the nixpkgs services. The oneshot generates
#      `/var/lib/pocket-id/secrets.env` (mode 0640, owned by
#      pocket-id:pocket-id) on first boot with:
#         ENCRYPTION_KEY=<random base64 32>
#         STATIC_API_KEY=<random base64 32>
#      The nixpkgs service loads this via `environmentFile`.
#      The env file is generated idempotently (only if missing),
#      so subsequent boots and rebuilds are no-ops.
#   4. Exposes PocketID via Caddy on `cococoir.auth.pocketid.domain`
#      when `public = true` (default).
#
# Why a runtime env file (not clan-core vars / SOPS)?
# ───────────────────────────────────────────────────
# PocketID is a single-instance service, not a cluster. The
# secrets don't need to be shared across machines, so the
# SOPS/clan-vars machinery (which exists for cluster-shared
# secrets like garage's RPC key) is unnecessary. The standard
# pattern for service secrets on NixOS is plaintext on disk,
# protected by disk encryption (LUKS). This is the same model
# PocketID itself uses in its docker-compose examples.
#
# The STATIC_API_KEY is special: per PocketID's docs, it
# "creates an admin account called 'Static API User' under
# the hood. This API key can be useful for declarative
# installations." We use it in Phase 2 (oidc-init) to create
# OIDC clients for each cococoir service via the API, with
# no human intervention.
#
# Phase 2 (not yet implemented):
#   - `pocket-id-oidc-init.service`: a oneshot that uses the
#     STATIC_API_KEY to call PocketID's API and create an OIDC
#     client per cococoir service that opts in via
#     `cococoir.services.<name>.oidc.enable = true`. Writes
#     the client_id + client_secret to a runtime file at
#     `/var/lib/pocket-id/clients/<service>.env`. Service
#     modules consume these via `cococoir.auth.derived.pocketid.clients.<name>`.
#   - `cococoir.lib.cococoir.withOidc`: a Caddy snippet helper
#     that adds forward_auth to a vhost. Requires a Caddy
#     build with the `caddy-security` plugin (PocketID's
#     recommended reverse-proxy integration per their docs).
#     For non-OIDC-native services (qBittorrent, CryptPad),
#     the user opts into this via
#     `cococoir.services.<name>.auth = "caddy-oidc"`.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.cococoir.auth.pocketid;
  dataDir = config.services.pocket-id.dataDir;
  secretsEnvFile = "${dataDir}/secrets.env";
in
{
  options.cococoir.auth.pocketid = {
    domain = mkOption {
      type = types.str;
      description = ''
        Public FQDN for PocketID (e.g. "auth.example.com"). PocketID
        will be served on this domain via Caddy when `public = true`.
      '';
    };

    public = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to expose PocketID via Caddy. Set to `false` to
        only access PocketID via a local network (Tailscale, VPN).
      '';
    };

    signupMode = mkOption {
      type = types.enum [ "disabled" "withToken" "open" ];
      default = "disabled";
      description = ''
        PocketID user signup mode:
        - "disabled": only admins can create users
        - "withToken": users need a signup token from an admin
        - "open": anyone can sign up (not recommended for public servers)
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.domain != "";
        message = ''
          cococoir.auth.pocketid.domain is required.
          Set it to the public FQDN where PocketID will be served.
        '';
      }
    ];

    # Nixpkgs services.pocket-id: the upstream service module.
    # We set PUBLIC_APP_URL, TRUST_PROXY, and ALLOW_USER_SIGNUPS
    # via `settings` (which generates a non-secret env file in
    # the nix store, safe for these values). The runtime secrets
    # are loaded via `environmentFile`, which points to the env
    # file written by the init oneshot below.
    services.pocket-id = {
      enable = true;
      settings = {
        PUBLIC_APP_URL = "https://${cfg.domain}";
        TRUST_PROXY = true;
        ALLOW_USER_SIGNUPS = cfg.signupMode;
      };
      environmentFile = secretsEnvFile;
    };

    # Init oneshot: generates /var/lib/pocket-id/secrets.env on
    # first boot. Idempotent: skips if the file already exists.
    # The file is mode 0640, owned by pocket-id:pocket-id, and
    # contains the two secrets PocketID needs at startup:
    #   - ENCRYPTION_KEY (used to encrypt OIDC token signing keys
    #     and other sensitive data; rotate via
    #     `pocket-id encryption-key-rotate --new-key <new>` per
    #     upstream docs)
    #   - STATIC_API_KEY (creates the "Static API User" admin,
    #     used for declarative OIDC client creation in Phase 2)
    #
    # The nixpkgs module sets up pocket-id's data dir via tmpfiles
    # (`d ${dataDir} 0755 pocket-id pocket-id`) so the dir exists
    # and is owned by pocket-id by the time this oneshot runs.
    # We `after = systemd-tmpfiles-setup.service` to be explicit.
    #
    # `before = [pocket-id-backend, pocket-id-frontend]` ensures
    # ordering; `Type=oneshot, RemainAfterExit=true` makes the
    # nixpkgs services wait for "exited with success" before
    # starting (via the after= override on the nixpkgs services
    # below — `before=` only orders, doesn't couple, so we also
    # add `after=` on the consumers).
    systemd.services.pocket-id-secret-init = {
      description = "PocketID secret init: generate ENCRYPTION_KEY and STATIC_API_KEY if missing";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      before = [ "pocket-id-backend.service" "pocket-id-frontend.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as root (no User=) so the script can chown the env
        # file to pocket-id:pocket-id. Root bypasses DAC, so the
        # "no User=" default (root) is what we want here.
        ExecStart = lib.getExe (pkgs.writeShellApplication {
          name = "pocket-id-secret-init";
          runtimeInputs = [ pkgs.coreutils pkgs.openssl ];
          text = ''
            set -euo pipefail
            if [ ! -f "${secretsEnvFile}" ]; then
              umask 0137
              {
                printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -base64 32)"
                printf 'STATIC_API_KEY=%s\n' "$(openssl rand -base64 32)"
              } > "${secretsEnvFile}"
              chown pocket-id:pocket-id "${secretsEnvFile}"
              chmod 0640 "${secretsEnvFile}"
              echo "[pocketid-secret-init] generated ${secretsEnvFile}"
            else
              echo "[pocketid-secret-init] ${secretsEnvFile} already exists, skipping"
            fi
          '';
        });
      };
    };

    # Make the nixpkgs pocket-id services wait for our init
    # oneshot. Without this, pocket-id-backend would try to
    # start before the secrets.env file exists, and fail with
    # "environment file not found" (systemd's
    # EnvironmentFile= requires the file to exist at service
    # start).
    systemd.services.pocket-id-backend.after = [ "pocket-id-secret-init.service" ];
    systemd.services.pocket-id-frontend.after = [ "pocket-id-secret-init.service" ];

    # Caddy vhost. Only when public=true (default). Caddy's
    # reverse_proxy directive sets X-Forwarded-Proto/For/Host
    # by default, which is what PocketID needs (we set
    # TRUST_PROXY=true above to tell PocketID to trust these
    # headers).
    services.caddy.virtualHosts = mkIf cfg.public {
      "${cfg.domain}".extraConfig = ''
        reverse_proxy http://127.0.0.1:1411
      '';
    };
  };
}
