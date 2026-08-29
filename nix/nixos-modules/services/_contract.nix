# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/_contract — the 4-option service contract
# factory. Per PLAN.md "Services" and ADR-004.
#
# Every cococoir service module (jellyfin.nix, dex.nix, ...)
# imports this factory and only adds its own specifics — system
# user, systemd unit, btrfs subvolume, env vars, etc. The factory owns:
#
#   - the standard option surface (enable / domain / public /
#     port / healthUrl / journald.units)
#   - the standard assertions (public → caddy, storageNeeded →
#     storage, baseDomain or explicit domain)
#   - the Caddy vhost with the right `tls` directive from
#     cococoir.tls and the right `reverse_proxy` / 403 from
#     `public`
#
# What the service adds (via `extraOptions` and `extraConfig`):
#   - per-service nixpkgs module activation (e.g. services.jellyfin)
#   - per-service system user / group
#   - per-service systemd unit
#   - per-service storage (auto-declare btrfs subvolumes)
#
# Adding a new service is then a single call to this factory with
# the service's specifics. The 4-option contract is enforced by
# code, not convention — drift (a missing health prober contract)
# is impossible.
#
# See:
#   - nix/nixos-modules/services/jellyfin.nix — 4-option example
#     with storageNeeded = true
#   - nix/nixos-modules/services/dex.nix — 3-option example
#     (storageNeeded = false)
#   - nix/tests/contract-conformance/default.nix — asserts every
#     service module uses this factory and exposes the standard
#     hidden options
#
# Per ADR-004: adding a 5th option to the standard contract is a
# deliberate decision, not an accident. Use `extraOptions` for
# per-service additions.
{lib, config, pkgs, options, ...}:
let
  inherit (lib) mkOption mkEnableOption types literalMD;
in
# mkCococoirService :: Attrs -> Module
# Returns a NixOS module that adds cococoir.services.<name>.* and
# the standard Caddy vhost + assertions. The caller composes
# this with per-service config (extraOptions + extraConfig).
args:
let
  cfg = config.cococoir.services.${args.name};
  hasBucket = args.storageNeeded or false;
  requires = args.requires or [];
  baseDomain = config.cococoir.baseDomain;
  sub = args.conventionalSubdomain or args.name;
in
{
  options.cococoir.services.${args.name} =
    let
      defaultEnable = args.defaultEnable or false;
    in
    {
      enable = mkOption {
        type = lib.types.bool;
        default = defaultEnable;
        defaultText = if defaultEnable then "true" else "false";
        description = if defaultEnable then ''
          Enable ${args.description}. **Always on** — the
          platform requires this service. Customers do not
          need to set this option; it is `true` by default.
          Set to `false` only to disable the service in a
          non-customer config (e.g. a test that doesn't need
          the OIDC provider).
        ''
        else ''
          Whether to enable ${args.description}.
        '';
      };

      domain = mkOption {
        type = types.str;
        default =
          if baseDomain == null
          then throw ''
            cococoir.services.${args.name}.domain: set `cococoir.baseDomain`
            at the top of the customer's config.nix, or override
            `cococoir.services.${args.name}.domain` explicitly.
          ''
          else "${sub}.${baseDomain}";
        defaultText = literalMD ''
          `` `${sub}.<baseDomain>` ``, where ``<baseDomain>`` is
          `cococoir.baseDomain`.
        '';
        description = ''
          External FQDN for the Caddy vhost. Defaults to
          ``${sub}`` + ``.`` + ``<baseDomain>`` when
          `cococoir.baseDomain` is set. Override per service for
          non-conventional names.
        '';
      };

      public = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the service is reachable from outside the host.
          `true` → Caddy reverse-proxies to the local port.
          `false` → Caddy returns 403. The Caddy vhost is the
          security boundary; do not bypass with firewall rules.
        '';
      };

      port = mkOption {
        type = types.port;
        default = args.defaultPort;
        description = ''
          Local TCP port ${args.name} binds to. The Caddy vhost
          reverse-proxies to `127.0.0.1:<this>`. Override only
          to avoid a port conflict.
        '';
        internal = true;
      };

      healthUrl = mkOption {
        type = types.str;
        default =
          "http://127.0.0.1:${toString args.defaultPort}${args.defaultHealthPath or "/health"}";
        description = ''
          URL the cococoir-client prober GETs for liveness
          (v2.4). Defaults to a localhost health endpoint.
        '';
        internal = true;
      };

      journald.units = mkOption {
        type = types.listOf types.str;
        default = ["${args.name}.service"];
        description = ''
          systemd units the cococoir-client journald tailer
          watches for OTEL log records (v2.5).
        '';
        internal = true;
      };
    }
    // (args.extraOptions or {});

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.domain != "";
            message = "cococoir.services.${args.name}.domain is empty.";
          }
          {
            assertion = cfg.public -> config.services.caddy.enable;
            message = ''
              cococoir.services.${args.name}: `public = true` requires
              `services.caddy.enable = true`. The Caddy vhost is
              the security boundary.
            '';
          }
          {
            assertion = !cfg.public || (builtins.match ".*bind 127.0.0.1.*" config.services.caddy.virtualHosts."${cfg.domain}".extraConfig != null);
            message = ''
              cococoir.services.${args.name}: the public Caddy vhost must
              `bind 127.0.0.1` (localhost). The client forwarder owns the
              tunnel IP as the external ingress and forwards to Caddy; a
              wildcard Caddy bind would collide with it (EADDRINUSE) and
              silently kill remote access.
            '';
          }
        ]
++ lib.optional hasBucket {
          assertion = hasBucket -> config.cococoir.storage.enable;
          message = ''
            cocococoir.services.${args.name}: `cococoir.storage.enable`
            is not set. ${args.name} requires the storage layer
            (btrfs pool + subvolumes).
          '';
        }
        ++ map (req: {
          assertion = cfg.enable -> config.cococoir.services.${req}.enable;
          message = ''
            cocococoir.services.${args.name}: requires
            `cococoir.services.${req}.enable`. Enable ${req} (or the
            ${req} service group) to use ${args.name}.
          '';
        }) requires;

        # ACME for this vhost traverses the tunnel (edge /128 → client
        # forwarder → localhost Caddy), so Caddy must not start before
        # the tunnel: a boot race fails the first orders and ACME backoff
        # leaves the domain certless for up to an hour after every boot
        # (auth/cryptpad incident, 2026-08-28). Ordering against a unit
        # that doesn't exist (compositions without the client) is a
        # systemd no-op.
        systemd.services.caddy = lib.mkIf config.services.caddy.enable {
          after = ["cococoir-client.service"];
        };

        services.caddy.virtualHosts."${cfg.domain}".extraConfig =
          lib.mkDefault (let
            tls = config.cococoir.tls;
            tlsLine =
              if tls.mode == "self-signed"
              then "tls ${tls.certFile} ${tls.keyFile}\n"
              else "";
          in
            # Bind Caddy to localhost only. The client forwarder owns the
            # tunnel IP (10.10.0.<n>:80/443) as the external ingress and
            # forwards to Caddy on 127.0.0.1; a wildcard Caddy bind would
            # collide with it (EADDRINUSE) and silently kill remote access.
            tlsLine + "bind 127.0.0.1 ::1\n" + (if cfg.public
              then "reverse_proxy 127.0.0.1:${toString cfg.port}"
              else ''respond "Forbidden" 403''));
      }
      ((args.extraConfig or (cfg: {}) ) { inherit cfg; lib = lib; config = config; pkgs = pkgs; options = options; })
    ]
  );
}
