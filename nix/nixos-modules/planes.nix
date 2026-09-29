# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/planes — access-plane routing + the failover redirect
# matrix (ADR-034).
#
# One origin per plane, every catalog service at `/<path>` on it:
#
#   clearnet  https://<baseDomain>     dashboard at /
#   LAN       http://<lanAddress>      dashboard at /, zero DNS
#   I2P       http://<i2pLabel>.i2p
#
# Every service answers at `/<path>` on every plane origin, and
# every service hostname 307s to its canonical shape — so `/<path>`
# is a uniform entry point whatever a service's routing mode, and a
# later routing flip ("swap the redirects") is one contract
# argument, not a migration. Redirects are 307, never 301: 301 is
# cached permanently and the flip must stay reversible.
#
#   routing = "path"       canonical = <plane origin><path>; the
#                          service hostnames are 307 stubs.
#   routing = "subdomain"  canonical = the service hostname; the
#                          plane's `/<path>` 307s to it. On the LAN
#                          the failover is a Caddy port-site
#                          (http://<lan>:<port>) so the whole
#                          catalog is reachable at the bare IP with
#                          zero DNS — `originLocked` apps (CryptPad)
#                          fail over to their hostname instead,
#                          because a second origin breaks them.
#
# All Caddy config for fortress services renders HERE; service
# modules never write services.caddy.virtualHosts — one renderer,
# no module-merge order seams. Two shared-origin seams are handled
# here as well: Set-Cookie gains Path=/<path> on plane proxies (so
# apps sharing an origin do not collide), and the loopback dex
# issuer's Location headers are rewritten once per plane onto that
# plane's dex surface (the issuer is never browser-reachable).
{
  lib,
  config,
  ...
}: let
  inherit (lib) mkOption types;
  servicesCfg = config.fortress.services;
  baseDomain = config.fortress.baseDomain;
  lan = config.fortress.network.lanAddress;
  bindAddrs = lib.concatStringsSep " " config.fortress.network.caddyBindAddresses;
  tlsCfg = config.fortress.tls;
  tlsLine =
    if tlsCfg.mode == "self-signed"
    then "tls ${tlsCfg.certFile} ${tlsCfg.keyFile}\n"
    else "";
  i2pLabel =
    if baseDomain == null
    then null
    else builtins.head (lib.splitString "." baseDomain);
  clearnetOrigin =
    if baseDomain == null then null else "https://${baseDomain}";
  lanOrigin = if lan == null then null else "http://${lan}";
  i2pOrigin = if i2pLabel == null then null else "http://${i2pLabel}.i2p";
  dashboardAddr = config.services.fortress-client.dashboardAddr;

  dex = servicesCfg.dex or null;
  dexOn = dex != null && (dex.enable or false);
  dexPort = if dexOn then toString dex.port else "";

  routable =
    lib.filterAttrs
    (_: s: (s.enable or false) && (s ? path) && (s ? routing))
    servicesCfg;
  routableNames = lib.sort (a: b: a < b) (lib.attrNames routable);

  escapeDots = s: lib.replaceStrings ["."] ["\\."] s;

  headerBlock = lines:
    lib.optionalString (lines != "") ''
      header {
      ${lines}    }
    '';

  issuerSwap = planeOrigin:
    lib.optionalString dexOn ''
      >Location "^http://127\.0\.0\.1:${dexPort}" "${planeOrigin}"
    '';

  cookieScope = path: ''>Set-Cookie "^(.+)$" "$1; Path=${path}"'';

  proxyHandle = name: s: ''
    @row-${name} path ${s.path} ${s.path}/*
    handle @row-${name} {
      route {
        ${lib.optionalString s.stripPath "uri strip_prefix ${s.path}\n"}        header ${cookieScope s.path}
        reverse_proxy 127.0.0.1:${toString s.port}
      }
    }
  '';

  aliasHandle = name: target: path: ''
    @row-${name} path ${path} ${path}/*
    handle @row-${name} {
      route {
        uri strip_prefix ${path}
        redir ${target}{uri} 307
      }
    }
    handle ${path} {
      redir ${target}/ 307
    }
  '';

  forbiddenHandle = name: path: ''
    @row-${name} path ${path} ${path}/*
    handle @row-${name} {
      respond "Forbidden" 403
    }
  '';

  planeRows = failover:
    lib.concatMapStrings (name: let s = routable.${name}; in
      if !s.public
      then forbiddenHandle name s.path
      else if s.routing == "path"
      then proxyHandle name s
      else aliasHandle name (failover s) s.path)
    routableNames;

  clearnetFailover = s: "https://${s.domain}";
  i2pFailover = s: "http://${s.i2pDomain}";
  lanFailover = s:
    if s.originLocked
    then "https://${s.domain}"
    else "http://${lan}:${toString s.port}";

  # Every plane keeps the browser on itself: a redirect to the
  # clearnet canonical origin is swapped onto the plane origin (I2P
  # additionally swaps subdomain-canonical service hostnames onto
  # their .i2p twins). The clearnet plane is the canonical, so it
  # swaps nothing.
  planeSwapLines = planeOrigin:
    lib.optionalString (planeOrigin != clearnetOrigin && clearnetOrigin != null) ''
      >Location "^https://${escapeDots baseDomain}(/|$)" "${planeOrigin}$1"
    '';

  i2pSwapLines =
    planeSwapLines i2pOrigin
    + lib.concatMapStrings (name: let s = routable.${name}; in
      lib.optionalString (s.public && s.routing == "subdomain") ''
        >Location "^https://${escapeDots s.domain}(/|$)" "http://${s.i2pDomain}$1"
      '')
    routableNames;

  planeExtra = {
    origin,
    failover,
    bind ? bindAddrs,
    tls ? "",
    swaps ? "",
  }: ''
    ${tls}bind ${bind}
    ${headerBlock (issuerSwap origin + swaps)}${planeRows failover}
    handle {
      reverse_proxy ${dashboardAddr}
    }
  '';

  stubExtra = {
    target,
    bind ? bindAddrs,
    tls ? "",
  }: ''
    ${tls}bind ${bind}
    redir ${target}{uri} 307
  '';

  serveExtra = {
    planeOrigin,
    s,
    bind ? bindAddrs,
    tls ? "",
  }: ''
    ${tls}bind ${bind}
    ${headerBlock (lib.optionalString s.public (issuerSwap planeOrigin))}${
      if s.public
      then "reverse_proxy 127.0.0.1:${toString s.port}"
      else ''respond "Forbidden" 403''
    }
  '';

  portSiteExtra = s: ''
    bind ${lan}
    ${headerBlock (issuerSwap lanOrigin)}reverse_proxy 127.0.0.1:${toString s.port}
  '';

  hostnameVhosts =
    lib.listToAttrs (lib.concatMap (name: let s = routable.${name}; in
      [
        {
          name = s.domain;
          value.extraConfig =
            if !s.public
            then serveExtra {planeOrigin = clearnetOrigin; inherit s; tls = tlsLine;}
            else if s.routing == "path"
            then stubExtra {target = "${clearnetOrigin}${s.path}"; tls = tlsLine;}
            else serveExtra {planeOrigin = clearnetOrigin; inherit s; tls = tlsLine;};
        }
      ]
      ++ lib.optional (s.public && i2pOrigin != null) {
        name = "http://${s.i2pDomain}";
        value.extraConfig =
          if s.routing == "path"
          then stubExtra {
            target = "${i2pOrigin}${s.path}";
            bind = "127.0.0.1";
          }
          else serveExtra {
            planeOrigin = i2pOrigin;
            inherit s;
            bind = "127.0.0.1";
          };
      })
    routableNames);

  portVhosts = lib.listToAttrs (lib.concatMap (name: let s = routable.${name}; in
    lib.optional (lan != null && s.public && s.routing == "subdomain" && !s.originLocked) {
      name = "http://${lan}:${toString s.port}";
      value.extraConfig = portSiteExtra s;
    })
    routableNames);

  planeVhosts =
    lib.optionalAttrs (clearnetOrigin != null) {
      "${baseDomain}".extraConfig = planeExtra {
        origin = clearnetOrigin;
        failover = clearnetFailover;
        tls = tlsLine;
      };
    }
    // lib.optionalAttrs (lanOrigin != null) {
      "http://${lan}".extraConfig = planeExtra {
        origin = lanOrigin;
        failover = lanFailover;
        swaps = planeSwapLines lanOrigin;
      };
    }
    // lib.optionalAttrs (i2pOrigin != null) {
      "http://${i2pLabel}.i2p".extraConfig = planeExtra {
        origin = i2pOrigin;
        failover = i2pFailover;
        bind = "127.0.0.1";
        swaps = i2pSwapLines;
      };
    };
in {
  options.fortress.planes = {
    clearnetOrigin = mkOption {
      type = types.nullOr types.str;
      readOnly = true;
      description = ''
        The clearnet plane origin (`https://<baseDomain>`) that every
        path-routed service hangs off; null when `fortress.baseDomain`
        is unset. Derived (ADR-034) — integration modules read it to
        build their per-plane callback URLs instead of re-deriving.
      '';
    };
    lanOrigin = mkOption {
      type = types.nullOr types.str;
      readOnly = true;
      description = ''
        The LAN plane origin (`http://<lanAddress>`), or null when
        `fortress.network.lanAddress` is unset. Derived (ADR-034).
      '';
    };
    i2pOrigin = mkOption {
      type = types.nullOr types.str;
      readOnly = true;
      description = ''
        The I2P plane origin (`http://<first baseDomain label>.i2p`),
        or null when `fortress.baseDomain` is unset. Derived (ADR-034).
      '';
    };
  };

  config = {
    fortress.planes = {inherit clearnetOrigin lanOrigin i2pOrigin;};

    assertions =
        [
          {
            assertion = builtins.elem "127.0.0.1" config.fortress.network.caddyBindAddresses;
            message = ''
              fortress/planes: fortress.network.caddyBindAddresses must
              contain 127.0.0.1 — the client forwarder owns the tunnel IP
              as the external ingress and forwards to Caddy on localhost.
            '';
          }
        ]
        ++ lib.mapAttrsToList (name: s: {
          assertion = s.routing != "path" || baseDomain != null;
          message = ''
            fortress/planes: ${name} is path-routed but
            `fortress.baseDomain` is null — path routing needs the clearnet
            origin it derives. Set `fortress.baseDomain`.
          '';
        })
        routable
        ++ [
          {
            assertion =
              lib.all (s: lib.hasPrefix "/" s.path && !(lib.hasSuffix "/" s.path))
              (lib.attrValues routable);
            message = ''
              fortress/planes: every service path must start with "/" and
              not end with "/" (got: ${lib.concatMapStringsSep ", " (s: s.path) (lib.attrValues routable)}).
            '';
          }
          {
            assertion =
              lib.length (lib.unique (map (s: s.path) (lib.attrValues routable)))
              == lib.length (lib.attrNames routable);
            message = ''
              fortress/planes: two enabled services share a path — one
              would silently shadow the other on every plane origin.
            '';
          }
        ];

      # Caddy must not start before the tunnel: ACME for the service
      # hostnames traverses it, and a boot race leaves domains certless
      # (auth/cryptpad incident, 2026-08-28). Ordering against a unit
      # that doesn't exist is a systemd no-op.
      systemd.services.caddy = lib.mkIf config.services.caddy.enable {
        after = ["fortress-client.service"];
      };

      services.caddy.virtualHosts = planeVhosts // hostnameVhosts // portVhosts;
  };
}
