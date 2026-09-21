# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/forgejo — Forgejo git forge.
#
# 4-option contract (per PLAN.md "Services" + ADR-004; see
# services/_contract.nix for the shared factory):
#   enable  — opt-in toggle
#   domain  — external FQDN for the Caddy vhost
#   public  — true → Caddy reverse-proxies; false → 403
#
# What the factory gives us for free:
#   - the options above + the hidden `port`, `healthUrl`,
#     `journald.units` options
#   - assertions (public → caddy, storageNeeded → storage,
#     domain set)
#   - the Caddy vhost with the right `tls` directive from
#     fortress.tls and the right `reverse_proxy` / 403
#
# What this module adds:
#   - activates nixpkgs' services.forgejo (SQLite, one box)
#   - binds loopback-only; Caddy is the ingress (the client
#     forwarder owns the tunnel IP)
#   - ROOT_URL = the clearnet domain so Forgejo builds its OIDC
#     callback on the public origin (dex integration wires the
#     rest — see integrations/forgejo-oidc.nix)
#   - DISABLE_SSH: the box's own sshd owns 22 and the forwarder
#     owns the tunnel-IP 80/443; git-over-HTTPS is the v1 path.
#   - DISABLE_REGISTRATION: a private forge — users come in via
#     Dex OIDC auto-registration (per-source, independent of this
#     switch), never via a public sign-up form.
#   - auto-declares the `forgejo-data` btrfs subvolume so repos +
#     DB land on the pool (btrfs tier) or /data (container tier)
#
# The health path /api/healthz is Forgejo's unauthenticated
# liveness endpoint (the same one its helm chart probes).
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  mkFortressService = import ./_contract.nix {inherit lib config pkgs options;};
in
  mkFortressService {
    name = "forgejo";
    description = "Forgejo git forge";
    defaultPort = 3001;
    defaultHealthPath = "/api/healthz";
    storageNeeded = true;
    conventionalSubdomain = "git";
    extraConfig = {
      cfg,
      lib,
      options,
      config,
      ...
    }: let
      btrfsStorage = config.fortress.storage.enable && config.fortress.storage.backend == "btrfs";
      dataRoot = config.fortress.storage.dataRoot;
      stateDir = "${dataRoot}/forgejo";
    in {
      services.forgejo = {
        enable = true;
        database.type = "sqlite3";
        stateDir = stateDir;

        settings = {
          server = {
            DOMAIN = cfg.domain;
            ROOT_URL = "https://${cfg.domain}/";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = cfg.port;
            DISABLE_SSH = true;
          };
          service.DISABLE_REGISTRATION = true;
          session.COOKIE_SECURE = true;
        };
      };

      # The forgejo user/group come from the nixpkgs services.forgejo
      # module (home = stateDir). The subvolume owner references them.

      fortress.storage.btrfs.subvolumes."forgejo-data" = {
        mountpoint = lib.mkDefault stateDir;
        quota = "20G";
        owner = {
          user = "forgejo";
          group = "forgejo";
          mode = "750";
        };
      };

      systemd.services.forgejo = {
        after = lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"];
        requires = lib.optionals btrfsStorage ["fortress-btrfs-subvolumes.service"];
        unitConfig.RequiresMountsFor = lib.optionals btrfsStorage [stateDir];
      };
    };
  }