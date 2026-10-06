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
#   - Identity is DynamicUser + StateDirectory (ADR-036): Forgejo
#     hard-refuses root, and the applier cannot create an account.
#     State lives under /var/lib/forgejo, which systemd re-owns on
#     every start — the only shape that is safe against dynamic-UID
#     recycling (systemd.exec(5)). The cost is that repos sit on the
#     root filesystem rather than the pool: no btrfs quota or
#     snapshots. Accepted deliberately.
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
    storageNeeded = false;
    conventionalSubdomain = "git";
    # ROOT_URL is URL-generation only: Forgejo serves at its own
    # root, so the plane row strips /git before proxying (ADR-034).
    stripPath = true;
    extraConfig = {
      cfg,
      lib,
      options,
      config,
      ...
    }: {
      services.forgejo = {
        enable = true;
        database.type = "sqlite3";
        stateDir = "/var/lib/forgejo";
        # `user`/`group` only feed nixpkgs' tmpfiles rules and its
        # users.users declaration. Pointing them at root keeps those
        # rules valid on a host the applier cannot add accounts to,
        # and the mkIf (cfg.user == "forgejo") guard keeps it from
        # declaring the account. The unit itself runs as the dynamic
        # `forgejo` below; RUN_USER must name it or Forgejo refuses
        # to start.
        user = "root";
        group = "root";

        settings = {
          server = {
            DOMAIN = config.fortress.baseDomain;
            ROOT_URL = "https://${config.fortress.baseDomain}${cfg.path}/";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = cfg.port;
            DISABLE_SSH = true;
          };
          DEFAULT.RUN_USER = "forgejo";
          service.DISABLE_REGISTRATION = true;
          session.COOKIE_SECURE = true;
        };
      };

      systemd.services.forgejo.serviceConfig = {
        DynamicUser = true;
        User = lib.mkForce "forgejo";
        Group = lib.mkForce "forgejo";
        StateDirectory = "forgejo";
      };
    };
  }