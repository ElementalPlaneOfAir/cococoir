# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/_contract — the 4-option service contract
# factory. Per PLAN.md "Services" and ADR-004.
#
# Every cococoir service module (jellyfin.nix, pocketid.nix, ...)
# imports this factory and only adds its own specifics — system
# user, systemd unit, FUSE mount, env vars, etc. The factory owns:
#
#   - the standard option surface (enable / domain / public /
#     [bucket] / port / healthUrl / journald.units)
#   - the standard assertions (public → caddy, bucket → storage,
#     baseDomain or explicit domain)
#   - the Caddy vhost with the right `tls` directive from
#     cococoir.tls and the right `reverse_proxy` / 403 from
#     `public`
#
# What the service adds (via `extraOptions` and `extraConfig`):
#   - per-service nixpkgs module activation (e.g. services.jellyfin)
#   - per-service system user / group
#   - per-service systemd unit
#   - per-service storage (auto-declare bucket + FUSE mount)
#
# Adding a new service is then a single call to this factory with
# the service's specifics. The 4-option contract is enforced by
# code, not convention — drift (like pocket-id lacking
# healthUrl/journald.units before this refactor) is impossible.
#
# See:
#   - nix/nixos-modules/services/jellyfin.nix — 4-option example
#   - nix/nixos-modules/services/pocketid.nix — 3-option example
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
  hasBucket = args ? defaultBucket && args.defaultBucket != null;
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
    // lib.optionalAttrs hasBucket {
      bucket = mkOption {
        type = types.str;
        default = args.defaultBucket;
        description = ''
          Name of the Garage bucket that backs ${args.name}'s
          data. The service module auto-declares it under
          `cococoir.storage.buckets` and a FUSE mount under
          `cococoir.storage.mounts` when enabled. Override
          only to share a bucket between services.
        '';
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
        ]
        ++ lib.optional hasBucket {
          assertion = config.cococoir.storage.enable;
          message = ''
            cococoir.services.${args.name}: `cococoir.storage.enable`
            is not set. ${args.name} requires the storage layer
            (Garage + FUSE mount).
          '';
        };

        services.caddy.virtualHosts."${cfg.domain}".extraConfig =
          lib.mkDefault (let
            tls = config.cococoir.tls;
            tlsLine =
              if tls.mode == "self-signed"
              then "tls ${tls.certFile} ${tls.keyFile}\n"
              else "";
          in
            tlsLine + (if cfg.public
              then "reverse_proxy 127.0.0.1:${toString cfg.port}"
              else ''respond "Forbidden" 403''));
      }
      ((args.extraConfig or (cfg: {}) ) { inherit cfg; lib = lib; config = config; pkgs = pkgs; options = options; })
    ]
  );
}
