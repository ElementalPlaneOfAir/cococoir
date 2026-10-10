# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/integrations/dex-gate — the Dex forward-auth gate.
#
# The *arrs have no OIDC support and no usable RBAC (the multi-user work is
# Sonarr#7186, a draft that was locked and never merged), so a browser
# cannot "log in with Dex" to them directly. Instead Dex fronts them: a
# request reaches radarr/sonarr/qbittorrent only after oauth2-proxy has
# vouched for it against Dex.
#
# The app's own auth is switched OFF wherever this gate applies —
# `AuthenticationMethod=External` for the *arrs (converged by _pin-arr),
# `LocalHostAuth = true` for qBittorrent. That is not a defence in depth
# reduction so much as a relocation: Servarr's External handler is the same
# as `None`, so whoever reaches the port gets in. The gate is the ONLY
# thing between a LAN client and these apps. It is therefore a hard
# assertion, not a nicety, that every gated route actually carries
# `forward_auth` (see nix/tests/applier-wiring).
#
# Group model (gate-policy.nix owns the rule):
#   admins  implicit member of every group — root
#   arr     radarr, sonarr, qbittorrent
#
# Group policy is per-request, not per-instance: oauth2-proxy's /oauth2/auth
# takes `?allowed_groups=<csv>` and answers 403 when the caller is not in
# any of them. One gate serves every group, and each Caddy route carries its
# own policy.
#
# The `/api` prefix is deliberately NOT gated (planes.nix): Prowlarr and
# mobile apps authenticate with X-Api-Key, and an HTML login redirect on
# that path silently breaks inter-*arr sync. The API key remains required on
# every API path regardless of auth method.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  inherit (import ./../gate-policy.nix {inherit lib;}) gateGroups;

  servicesCfg = config.fortress.services;
  dx = servicesCfg.dex or {};
  dxOn = dx.enable or false;

  gated =
    lib.filterAttrs
    (_: s: (s.accessGroup or null) != null)
    servicesCfg;
  gatedNames = lib.attrNames gated;
  gateOn = dxOn && gatedNames != [];

  # Distinct groups the gate must honour, and the ones a user must be in.
  requiredGroups = lib.unique (lib.mapAttrsToList (_: s: s.accessGroup) gated);

  # oauth2-proxy's callback. The canonical origin is the one registered as
  # the OIDC redirect_uri; the per-plane twins are registered too so the
  # plane-swap Location rewrite can bring the browser back to the plane it
  # started on (planes.nix `planeSwapLines`).
  canonicalOrigin =
    config.fortress.planes.clearnetOrigin or config.fortress.planes.lanOrigin or null;
  callbackPath = "/oauth2/callback";
  callbackURL =
    if canonicalOrigin == null
    then throw "fortress/dex-gate: no clearnet or LAN origin to hang the OAuth callback off — set fortress.baseDomain or fortress.network.lanAddress"
    else "${canonicalOrigin}${callbackPath}";

  redirectURIs =
    lib.optional (config.fortress.planes.clearnetOrigin != null)
    "${config.fortress.planes.clearnetOrigin}${callbackPath}"
    ++ lib.optional (config.fortress.planes.lanOrigin != null)
    "${config.fortress.planes.lanOrigin}${callbackPath}"
    ++ lib.optional (config.fortress.planes.i2pOrigin != null)
    "${config.fortress.planes.i2pOrigin}${callbackPath}";

  dexUsers = config.services.dex.settings.staticPasswords or [];
  # A user passes a gate when they are in its group, or are root.
  canPass = group:
    lib.any
    (u: lib.elem group (u.groups or []) || lib.elem "admins" (u.groups or []))
    dexUsers;
  unreachable = lib.filter (g: !(canPass g)) requiredGroups;
in {
  options.fortress.gate = {
    authUpstream = mkOption {
      type = types.str;
      default = "http://127.0.0.1:4180";
      description = ''
        Where Caddy sends its `forward_auth` preflight. Always loopback:
        the gate is never itself exposed. planes.nix reads this to build
        the gated rows.
      '';
    };
  };

  config = lib.mkIf gateOn {
    # The gate is the only auth in front of these apps, so a lockout here is
    # not a soft failure: nobody can reach their own library. Fail the build
    # rather than ship a box that boots to a login nobody can pass.
    assertions = [
      {
        assertion = unreachable == [];
        message = ''
          fortress/dex-gate: these gate groups have no member who can pass:
          ${toString unreachable}. A user passes group G only if their Dex
          `groups` contain G or "admins". Either add a user to one of
          ${toString requiredGroups} in services.dex.settings.staticPasswords,
          or make one of them an admin. Without this, ${toString gatedNames}
          would be reachable by nobody at all.
        '';
      }
    ];

    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      oidcIssuerUrl = "http://127.0.0.1:${toString dx.port}/dex";
      clientID = "fortress-gate";
      # `keyFile` carries OAUTH2_PROXY_CLIENT_SECRET and
      # OAUTH2_PROXY_COOKIE_SECRET — never the values themselves, which stay
      # sealed (sops-wire.nix).
      keyFile = config.sops.templates."oauth2-proxy.env".path;
      redirectURL = callbackURL;
      upstream = ["static://202"];
      scope = "openid profile email groups";
      email.domains = ["*"];
      reverseProxy = true;
      # One address, one definition — planes.nix sends its preflight here.
      httpAddress = config.fortress.gate.authUpstream;
      cookie = {
        # Host-only: each plane keeps its own session, so a clearnet cookie
        # is never replayed against the I2P surface (and vice versa).
        domain = null;
        # The LAN and I2P planes are plain HTTP by design, so a Secure
        # cookie would never come back. Clearnet still forces HTTPS via its
        # 308, so the cookie is not sent in the clear there.
        secure = false;
        httpOnly = true;
      };
    };

    # Dex must know the gate as a client, exactly as jellyfin/cryptpad/forgejo
    # register theirs.
    services.dex.settings.staticClients = lib.mkAfter [
      {
        id = "fortress-gate";
        name = "Fortress Gate";
        inherit redirectURIs;
        secretFile = config.sops.secrets.oidc-gate-secret.path;
      }
    ];

    # oauth2-proxy reads Dex over the loopback issuer and must see the
    # secrets materialize first.
    systemd.services.oauth2-proxy = {
      after = ["sops-install-secrets.service" "dex.service"];
      requires = ["sops-install-secrets.service"];
    };
  };
}
