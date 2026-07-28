# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/dex — Dex OIDC provider.
#
# 3-option contract (infra, no per-tenant bucket):
#   enable  — opt-in toggle (always-on; the platform requires OIDC)
#   domain  — public FQDN; the OIDC issuer URL is
#             "https://${domain}/dex"
#   public  — true → Caddy reverse-proxies; false → 403
#
# What the factory gives us for free:
#   - the three options above + the hidden `port`, `healthUrl`,
#     `journald.units` options
#   - assertions (public → caddy, domain set)
#   - the Caddy vhost with the right `tls` directive from
#     cococoir.tls and the right `reverse_proxy` / 403
#
# This module wraps nixpkgs' services.dex. The nixpkgs module
# handles the systemd unit, config YAML generation, and secret-file
# substitution via replace-secret. This module adds:
#   - the cococoir contract (domain / port / Caddy)
#   - SQLite persistence under StateDirectory
#   - a DynamicUser override so the DB is writable
#
# OIDC clients and static users are added by integration modules
# (e.g. jellyfin-oidc.nix) by setting services.dex.settings directly.
# There is no API — everything is declarative config.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "dex";
  description = "Dex OIDC provider";
  defaultEnable = true;
  defaultPort = 5556;
  defaultHealthPath = "/dex/.well-known/openid-configuration";
  conventionalSubdomain = "auth";
  extraConfig = {cfg, ...}: {
    services.dex = {
      enable = true;
      settings = lib.mkMerge [
        {
          issuer = "https://${cfg.domain}/dex";
          web.http = "127.0.0.1:${toString cfg.port}";
          storage.type = "sqlite3";
          storage.config.file = "/var/lib/dex/dex.db";
          enablePasswordDB = true;
          oauth2.passwordConnector = "local";
        }
      ];
    };

    systemd.services.dex.serviceConfig = {
      StateDirectory = "dex";
    };
  };
}
