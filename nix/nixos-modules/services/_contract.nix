# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/_contract — the 4-option service contract
# factory. Per PLAN.md "Services" and ADR-004.
#
# Every fortress service module (jellyfin.nix, dex.nix, ...)
# imports this factory and only adds its own specifics — system
# user, systemd unit, btrfs subvolume, env vars, etc. The factory owns:
#
#   - the standard option surface (enable / domain / public /
#     port / healthUrl / journald.units)
#   - the standard assertions (public → caddy, storageNeeded →
#     storage, baseDomain or explicit domain)
#   - the Caddy vhost with the right `tls` directive from
#     fortress.tls and the right `reverse_proxy` / 403 from
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
# mkFortressService :: Attrs -> Module
# Returns a NixOS module that adds fortress.services.<name>.* and
# the standard Caddy vhost + assertions. The caller composes
# this with per-service config (extraOptions + extraConfig).
args:
let
  cfg = config.fortress.services.${args.name};
  hasBucket = args.storageNeeded or false;
  requires = args.requires or [];
  baseDomain = config.fortress.baseDomain;
  sub = args.conventionalSubdomain or args.name;
  # Platform-owned bind list (fortress.network.caddyBindAddresses):
  # localhost, plus the LAN address when fortress.network.lanAddress
  # is set — so LAN devices that resolve a service domain via the
  # box's dnsmasq (ADR-028) terminate TLS on the box directly. Never
  # 0.0.0.0: the forwarder owns the tunnel IP.
  bindAddrs = lib.concatStringsSep " " config.fortress.network.caddyBindAddresses;
  # I2P plane naming: every public vhost gets a plain-HTTP twin at
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
  escapeDots = s: lib.replaceStrings ["."] ["\\."] s;
  dexOn = (options.fortress.services ? dex) && config.fortress.services.dex.enable;
  dexPort = toString config.fortress.services.dex.port;
  dexClearnetUrl = "https://${config.fortress.services.dex.domain}";
  dexI2pUrl = "http://${config.fortress.services.dex.i2pDomain}";
  # The dex issuer is a loopback address — never browser-reachable.
  # Every vhost rewrites any redirect to it onto the dex surface of
  # its own path: clearnet vhosts → the clearnet dex origin, I2P
  # vhosts → the I2P dex origin. The `>` prefix defers the replace
  # until the response header is written; `$`-free find/replace keeps
  # the untouched remainder of the Location value.
  issuerLocationRewrite = target:
    "header >Location \"^http://127\\.0\\.0\\.1:${dexPort}\" \"${target}\"\n";
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
          "http://127.0.0.1:${toString args.defaultPort}${args.defaultHealthPath or "/health"}";
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
          {
            assertion = !cfg.public || (builtins.match ".*bind 127.0.0.1.*" config.services.caddy.virtualHosts."${cfg.domain}".extraConfig != null);
            message = ''
              fortress.services.${args.name}: the public Caddy vhost must
              `bind 127.0.0.1` (localhost). The client forwarder owns the
              tunnel IP as the external ingress and forwards to Caddy; a
              wildcard Caddy bind would collide with it (EADDRINUSE) and
              silently kill remote access.
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

        # ACME for this vhost traverses the tunnel (edge /128 → client
        # forwarder → localhost Caddy), so Caddy must not start before
        # the tunnel: a boot race fails the first orders and ACME backoff
        # leaves the domain certless for up to an hour after every boot
        # (auth/cryptpad incident, 2026-08-28). Ordering against a unit
        # that doesn't exist (compositions without the client) is a
        # systemd no-op.
        systemd.services.caddy = lib.mkIf config.services.caddy.enable {
          after = ["fortress-client.service"];
        };

        services.caddy.virtualHosts."${cfg.domain}".extraConfig =
          lib.mkDefault (let
            tls = config.fortress.tls;
            tlsLine =
              if tls.mode == "self-signed"
              then "tls ${tls.certFile} ${tls.keyFile}\n"
              else "";
          in
            # Bind to fortress.network.caddyBindAddresses (localhost +
            # LAN address when set). The client forwarder owns the
            # tunnel IP (10.10.0.<n>:80/443) as the external ingress and
            # forwards to Caddy on 127.0.0.1; a wildcard Caddy bind would
            # collide with it (EADDRINUSE) and silently kill remote access.
            tlsLine + "bind ${bindAddrs}\n"
            + (if dexOn then issuerLocationRewrite dexClearnetUrl else "")
            + (if cfg.public
              then "reverse_proxy 127.0.0.1:${toString cfg.port}"
              else ''respond "Forbidden" 403''));

        # Plain-HTTP twin for the I2P plane: loopback-only bind (the
        # I2P tunnel is the local ingress), no TLS, no ACME, no
        # HTTP→HTTPS redirect. The issuer rewrite points at the I2P
        # dex origin so the SSO redirect chain stays on the path the
        # browser is already on.
        services.caddy.virtualHosts."http://${cfg.i2pDomain}".extraConfig =
          lib.mkIf cfg.public (lib.mkDefault
            ("bind 127.0.0.1\n"
            + (if dexOn then issuerLocationRewrite dexI2pUrl else "")
            + "reverse_proxy 127.0.0.1:${toString cfg.port}"));
      }
      ((args.extraConfig or (cfg: {}) ) { inherit cfg; lib = lib; config = config; pkgs = pkgs; options = options; })
    ]
  );
}
