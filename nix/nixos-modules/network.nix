# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/network — the LAN access plane (ADR-028).
#
# One customer-facing option:
#
#   fortress.network.lanAddress = "192.168.1.10";
#
# (the box's static LAN IPv4, i.e. a DHCP reservation on the router)
# plus one router change: point the router's DHCP DNS at that address.
# Everything else derives:
#
#   - fortress.network.dns.enable defaults to true when lanAddress is
#     set — setting the address IS the intent signal. No second toggle.
#   - dnsmasq (DNS only; the router keeps DHCP) answers every enabled
#     service's `domain` with lanAddress, enumerated from
#     fortress.services — new catalog services are covered with zero
#     config. Other queries forward upstream via the box's own
#     resolver config (resolv.conf), so no loop is possible as long as
#     the box does not resolve from itself (asserted below).
#   - NXDOMAIN for use-application-dns.net: the Firefox DoH canary.
#     Browsers with "Secure DNS" enabled would bypass split-horizon
#     entirely; this auto-disables it on Firefox. Default-on, no option.
#   - The service factory's Caddy vhosts bind
#     fortress.network.caddyBindAddresses (localhost + lanAddress), so
#     LAN traffic terminates TLS on the box directly. The forwarder's
#     tunnel IP (10.10.0.<n>:443) stays the remote ingress; a wildcard
#     bind would still collide with it (EADDRINUSE), hence the explicit
#     address list instead of 0.0.0.0.
#
# Split-horizon safety (ADR-028): the global answer (edge /128 →
# tunnel) keeps working, so the local override is an optimization
# with a working fallback, not a lie. DoH bypass degrades to the
# tunnel path.
#
# Why a static address: dnsmasq could answer per-interface
# dynamically (auth-zone), but Caddy's bind is render-time — with a
# DHCP address there is nothing to bind. Runtime config rewriting is
# the fragile version of the same feature. A home server wants a DHCP
# reservation anyway.
{lib, config, ...}:
let
  inherit (lib) mkOption types;
  cfg = config.fortress.network;

  # Domains of every enabled factory service. Derived, never
  # configured — dnsmasq coverage tracks the service tree.
  enabledDomains =
    lib.unique
      (lib.mapAttrsToList (_: s: s.domain)
        (lib.filterAttrs (_: s: s.enable or false) config.fortress.services));
in
{
  options.fortress.network = {
    lanAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.1.10";
      description = ''
        The box's static LAN IPv4 address. Set this (a DHCP
        reservation on the router, or static config) and point the
        router's DHCP DNS at it: LAN devices then resolve every
        service directly to the box — no internet transit, no
        tunnel. Leave null on boxes without LAN service (the DNS
        layer stays off).
      '';
    };

    dns.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the LAN DNS layer (dnsmasq) serving every enabled
        service's domain with `lanAddress`. Defaults to true when
        `fortress.network.lanAddress` is set.
      '';
    };

    caddyBindAddresses = mkOption {
      type = types.listOf types.str;
      internal = true;
      default = ["127.0.0.1" "::1"] ++ lib.optional (cfg.lanAddress != null) cfg.lanAddress;
      description = ''
        Addresses every fortress Caddy vhost binds. Localhost (the
        forwarder's ingress target) plus the LAN address when set.
        Never 0.0.0.0 — the forwarder owns the tunnel IP and a
        wildcard bind would collide (EADDRINUSE).
      '';
    };
  };

  config = lib.mkMerge [
    # Auto-activation outside the mkIf — the gate itself must not be
    # defined inside its own gate.
    { fortress.network.dns.enable = lib.mkDefault (cfg.lanAddress != null); }

    (lib.mkIf cfg.dns.enable {
      assertions = [
        {
          assertion = cfg.lanAddress != null;
          message = ''
            fortress.network.dns: enabled but `fortress.network.lanAddress`
            is null. Set the box's static LAN address (a DHCP reservation).
          '';
        }
        {
          assertion = !builtins.elem cfg.lanAddress config.networking.nameservers;
          message = ''
            fortress.network: `networking.nameservers` contains
            ${cfg.lanAddress} — the box would forward upstream queries
            to its own dnsmasq (resolver loop).
          '';
        }
      ];

      services.dnsmasq = {
        enable = true;
        # DNS server for the LAN only. The box keeps resolving via its
        # own resolver config; the router keeps DHCP.
        resolveLocalQueries = false;
        settings = {
          listen-address = [cfg.lanAddress];
          bind-interfaces = true;
          # Never serve the box's /etc/hosts to the LAN (it maps the
          # service domains to 127.0.0.1 for the box's own use).
          no-hosts = true;
          address =
            # Firefox DoH canary: NXDOMAIN makes Firefox drop
            # "Secure DNS" on this network (RFC 8764-ish precedent).
            ["/use-application-dns.net/"]
            ++ map (d: "/${d}/${cfg.lanAddress}") enabledDomains;
        };
      };

      networking.firewall.allowedTCPPorts = [53];
      networking.firewall.allowedUDPPorts = [53];

      # Both units bind concrete addresses that DHCP may deliver late;
      # a start-before-address race shows up as a failed bind.
      systemd.services.dnsmasq = {
        after = ["network-online.target"];
        wants = ["network-online.target"];
      };
      systemd.services.caddy = lib.mkIf config.services.caddy.enable {
        after = ["network-online.target"];
      };
    })
  ];
}
