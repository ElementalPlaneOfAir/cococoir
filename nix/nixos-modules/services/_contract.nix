# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/_contract — the 4-option service contract
# factory. Per PLAN.md "Services", ADR-004, and ADR-034 (routing:
# one origin per plane, services at paths, failover redirect matrix).
#
# Every fortress service module (jellyfin.nix, dex.nix, ...)
# imports this factory and only adds its own specifics — system
# user, systemd unit, btrfs subvolume, env vars, etc. The factory owns:
#
#   - the standard option surface (enable / domain / public /
#     routing / path / port / healthUrl / journald.units)
#   - the standard assertions (public → caddy, storageNeeded →
#     storage, baseDomain or explicit domain)
#
# What the service adds (via `extraOptions` and `extraConfig`):
#   - per-service nixpkgs module activation (e.g. services.jellyfin)
#   - per-service systemd unit
#   - per-service storage (auto-declare btrfs subvolumes)
#
# Caddy rendering does NOT live here: `planes.nix` reads these
# options and renders every vhost (plane origins + service hostnames
# + LAN port-sites) from one matrix — one renderer, no module-merge
# order seams (ADR-034).
#
# Adding a new service is then a single call to this factory with
# the service's specifics. The contract is enforced by code, not
# convention — drift (a missing health prober contract) is
# impossible.
#
# See:
#   - nix/nixos-modules/services/jellyfin.nix — 4-option example
#     with storageNeeded = true
#   - nix/nixos-modules/services/dex.nix — 3-option example
#     (storageNeeded = false)
#   - nix/nixos-modules/planes.nix — the routing plane layer
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
# mkFortressService :: Attrs -> Module
# Returns a NixOS module that adds fortress.services.<name>.* and
# the standard assertions. The caller composes this with per-service
# config (extraOptions + extraConfig).
args:
let
  cfg = config.fortress.services.${args.name};
  hasBucket = args.storageNeeded or false;
  requires = args.requires or [];
  baseDomain = config.fortress.baseDomain;
  sub = args.conventionalSubdomain or args.name;
  # I2P plane naming: every public service gets a plain-HTTP twin at
  # `<domain first label>.<baseDomain first label>.i2p`, derived —
  # never a customer-facing option. Fail loud when baseDomain is
  # unset: there is no name to derive, and silent absence would be
  # a silent-failure seam.
  i2pLabel =
    if baseDomain == null
    then throw ''
      fortress.services.${args.name}: the I2P plane derives its
      hostname label from the first DNS label of
      `fortress.baseDomain`; set `fortress.baseDomain` or override
      `fortress.services.${args.name}.i2pDomain` explicitly.
    ''
    else builtins.head (lib.splitString "." baseDomain);
in
{
  options.fortress.services.${args.name} =
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

      # Customer-facing one-liner, shown on the service's dashboard
      # card. Set at the factory call alongside `name`, never by the
      # customer — it is display metadata, not config (ADR-004).
      description = mkOption {
        type = types.str;
        default = args.description;
        defaultText = literalMD ''the service's one-line description'';
        description = ''
          One-line description shown on the service's dashboard card.
          Derived from the service module's factory call.
        '';
        internal = true;
      };

      domain = mkOption {
        type = types.str;
        default =
          if baseDomain == null
          then throw ''
            fortress.services.${args.name}.domain: set `fortress.baseDomain`
            at the top of the customer's config.nix, or override
            `fortress.services.${args.name}.domain` explicitly.
          ''
          else "${sub}.${baseDomain}";
        defaultText = literalMD ''
          `` `${sub}.<baseDomain>` ``, where ``<baseDomain>`` is
          `fortress.baseDomain`.
        '';
        description = ''
          External FQDN for the Caddy vhost. Defaults to
          ``${sub}`` + ``.`` + ``<baseDomain>`` when
          `fortress.baseDomain` is set. Override per service for
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

      routing = mkOption {
        type = types.enum ["path" "subdomain"];
        default = args.routing or "path";
        defaultText = literalMD ''`"path"`'';
        description = ''
          Where this service's canonical URLs live (ADR-034).

          `"path"` — canonical at `<plane origin>${args.path or "/${sub}"}`;
          the service hostname is a 307 stub to it.

          `"subdomain"` — canonical at the service hostname; the
          plane origin's ``${args.path or "/${sub}"}`` is a 307
          failover row (on the LAN it targets the service's Caddy
          port-site, so the catalog works at the bare IP).

          A platform fact from the base-path audit, not customer
          config. Flipping it swaps the failover redirects.
        '';
        internal = true;
      };

      path = mkOption {
        type = types.str;
        default = args.path or "/${sub}";
        defaultText = literalMD ''`/${sub}`'';
        description = ''
          The service's entry point on every plane origin — its
          base path when `routing = "path"`, its failover alias
          when `routing = "subdomain"`. Derived from the
          conventional subdomain; override for services whose
          surface lives elsewhere (dex serves at `/dex`).
        '';
        internal = true;
      };

      originLocked = mkOption {
        type = types.bool;
        default = args.originLocked or false;
        defaultText = literalMD ''`false`'';
        description = ''
          The app pins its own origin (CryptPad's safe/unsafe
          origin model) and breaks on a second one. Such services
          fail over to their hostname, never to a LAN port-site.
        '';
        internal = true;
      };

      stripPath = mkOption {
        type = types.bool;
        default = args.stripPath or false;
        defaultText = literalMD ''`false`'';
        description = ''
          The app generates URLs carrying `<path>` (its `ROOT_URL`)
          but serves at its own root — the plane row strips `<path>`
          before proxying (Forgejo works this way; its `ROOT_URL` is
          URL-generation only). Jellyfin/dex/*arr `BaseUrl`-style
          knobs instead make the app serve *under* the path, and
          those rows preserve it. The prober's loopback URL matches
          whichever shape the app serves.
        '';
        internal = true;
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

      i2pDomain = mkOption {
        type = types.str;
        default = "${builtins.head (lib.splitString "." cfg.domain)}.${i2pLabel}.i2p";
        description = ''
          Plain-HTTP hostname for this service on the I2P plane,
          derived from the service's clearnet subdomain and the
          first DNS label of `fortress.baseDomain`. Never
          customer-facing; served by Caddy over the I2P tunnel.
        '';
        internal = true;
      };

      healthUrl = mkOption {
        type = types.str;
        default =
          "http://127.0.0.1:${toString args.defaultPort}"
          + lib.optionalString (cfg.routing == "path" && !cfg.stripPath) cfg.path
          + (args.defaultHealthPath or "/health");
        description = ''
          URL the fortress-client prober GETs for liveness
          (v2.4). Defaults to a localhost health endpoint.
        '';
        internal = true;
      };

      journald.units = mkOption {
        type = types.listOf types.str;
        default = ["${args.name}.service"];
        description = ''
          systemd units the fortress-client journald tailer
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
            message = "fortress.services.${args.name}.domain is empty.";
          }
          {
            assertion = cfg.public -> config.services.caddy.enable;
            message = ''
              fortress.services.${args.name}: `public = true` requires
              `services.caddy.enable = true`. The Caddy vhost is
              the security boundary.
            '';
          }
        ]
++ lib.optional hasBucket {
          assertion = hasBucket -> config.fortress.storage.enable;
          message = ''
            cofortress.services.${args.name}: `fortress.storage.enable`
            is not set. ${args.name} requires the storage layer
            (btrfs pool + subvolumes).
          '';
        }
        ++ map (req: {
          assertion = cfg.enable -> config.fortress.services.${req}.enable;
          message = ''
            cofortress.services.${args.name}: requires
            `fortress.services.${req}.enable`. Enable ${req} (or the
            ${req} service group) to use ${args.name}.
          '';
        }) requires;
      }
      ((args.extraConfig or (cfg: {}) ) { inherit cfg; lib = lib; config = config; pkgs = pkgs; options = options; })
    ]
  );
}
