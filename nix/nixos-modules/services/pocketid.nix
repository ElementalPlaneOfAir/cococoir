# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/pocketid — Pocket-ID OIDC provider.
#
# 3-option contract (intentionally NOT 4 like the tenant-data
# services — pocket-id is infra, not tenant data, and has no
# per-tenant bucket to declare; see PLAN.md v2.2.5):
#   enable   — opt-in toggle
#   domain   — public FQDN; the OIDC issuer URL is
#              "https://${domain}". Caddy vhost name. The
#              factory's `conventionalSubdomain = "auth"` means
#              the default is `auth.<baseDomain>` (e.g.
#              `auth.alice.example.com`), which reads better
#              than `pocketid.<baseDomain>` on every login
#              screen.
#   public   — true → Caddy reverse-proxies to pocket-id;
#              false → 403
#
# What the factory gives us for free:
#   - the three options above + the hidden `port`, `healthUrl`,
#     `journald.units` options
#   - assertions (public → caddy, domain set, default healthUrl
#     derived from the OIDC discovery endpoint)
#   - the Caddy vhost with the right `tls` directive from
#     cococoir.tls and the right `reverse_proxy` / 403
#
# What this module adds (via `extraOptions` and `extraConfig`):
#   - two secret-file options (encryptionKeyFile required,
#     staticApiKeyFile optional) wired in via the factory's
#     extra options
#   - the pocketid system user + tmpfiles rules
#   - the systemd unit with the right env vars and static-user
#     security boundary
#
# SQLite on local disk (not the cococoir bucket) because SQLite
# + FUSE fsync semantics are not great for a primary auth
# database. For multi-host setups, switch pocket-id to
# PostgreSQL via DB_CONNECTION_STRING.
#
# OIDC client creation lives in cococoir.integrations.oidc
# (or is done out of band via pocket-id's admin API). This
# module only owns "run pocket-id under cococoir".
{
  config,
  lib,
  pkgs,
  ...
}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs;};
in
mkCococoirService {
  name = "pocketid";
  description = "Pocket-ID OIDC provider";
  defaultEnable = true; # OIDC is always-on; the platform requires it.
  defaultPort = 1411;
  defaultHealthPath = "/.well-known/openid-configuration";
  conventionalSubdomain = "auth";
  extraOptions = {
    encryptionKeyFile = lib.mkOption {
      type = lib.types.path;
      example = "/run/secrets/pocketid-encryption-key";
      description = ''
        Path to a file containing the pocket-id ENCRYPTION_KEY
        (base64-encoded, ≥16 bytes). The file MUST NOT have a
        trailing CR/LF — pocket-id treats line terminators as
        part of the key, and a stray newline will fail
        decryption on restart. In production this points at a
        sops-nix secret at `/run/secrets/...`; in the dev VM
        it's build-time-generated.
      '';
    };

    staticApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/pocketid-static-api-key";
      description = ''
        Optional path to STATIC_API_KEY. When set, pocket-id
        auto-creates a "Static API User" admin on first boot,
        so the OIDC server is adminable without the setup
        wizard. Recommended for dev VMs and any CI-driven
        environment.
      '';
    };
  };
  extraConfig = {cfg, ...}: {
    users.users.pocketid = {
      isSystemUser = true;
      home = "/var/lib/pocket-id";
      group = "pocketid";
      uid = 1000; # match pocket-id's PUID=1000 default
      description = "Pocket-ID OIDC provider";
    };
    users.groups.pocketid = {gid = 1000;};

    systemd.tmpfiles.rules = [
      "d /var/lib/pocket-id 0700 pocketid pocketid -"
      "d /var/lib/pocket-id/data 0700 pocketid pocketid -"
    ];

    systemd.services.pocketid = {
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      environment = {
        APP_URL = "https://${cfg.domain}";
        HOST = "127.0.0.1";
        PORT = toString cfg.port;
        PUID = "1000";
        PGID = "1000";
        ENCRYPTION_KEY_FILE = cfg.encryptionKeyFile;
      }
      // lib.optionalAttrs (cfg.staticApiKeyFile != null) {
        STATIC_API_KEY_FILE = cfg.staticApiKeyFile;
      };
      serviceConfig = {
        ExecStart = lib.getExe pkgs.pocket-id;
        WorkingDirectory = "/var/lib/pocket-id";
        User = "pocketid";
        Group = "pocketid";
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "pocket-id";
        # pocket-id refuses to run as root; the static
        # user + StateDirectory handle that.
      };
    };
  };
}
