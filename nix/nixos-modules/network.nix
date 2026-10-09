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
#     set — setting the address IS the intent signal. No second toggle
#     to reach the happy path; `dns.enable = false` still turns the
#     plane off on a box that has an address but no LAN service.
#   - fortress-dns (dnsmasq, DNS only; the router keeps DHCP) answers
#     every enabled service's `domain` — and `fortress.baseDomain`, the
#     shared path-routing origin (ADR-034) — with lanAddress, enumerated
#     from fortress.services — new catalog services are covered with
#     zero config. Other queries forward upstream via the box's own
#     resolver config (resolv.conf), so no loop is possible as long as
#     the box does not resolve from itself (asserted below).
#   - NXDOMAIN for use-application-dns.net: the Firefox DoH canary.
#     Browsers with "Secure DNS" enabled would bypass split-horizon
#     entirely; this auto-disables it on Firefox. Default-on, no option.
#   - `fortress.network.caddyBindAddresses` (the wildcard) is the
#     bind list the routing layer (`planes.nix`) renders every
#     fortress Caddy vhost with, so Caddy terminates on every
#     interface (LAN, tailnet, tunnel) with no per-interface config.
#     The tunnel forwarder no longer contends for :80/:443 on the
#     tunnel IP — it listens on a distinct client port (the control
#     plane's port map), so the wildcard is collision-free.
#
# The unit is fortress-owned rather than nixpkgs' dnsmasq module:
# that module writes /etc, declares `users.users.dnsmasq`, and registers
# on dbus (Type = "dbus"), none of which the ADR-035 applier can honor —
# it installs units into /run/systemd/system on a host whose /etc is
# read-only (NixOS) and whose users the OS owns. One definition serves
# `nixosModules.default` and `systemConfigs.*` alike: the config file is
# a store path, so the unit never touches the host's /etc.
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
{
  lib,
  pkgs,
  config,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.fortress.network;
  baseDomain = config.fortress.baseDomain;

  # Domains of every enabled factory service. Derived, never
  # configured — dnsmasq coverage tracks the service tree. The
  # aggregate toggles (e.g. `media`) carry no vhost of their own —
  # only factory services have a domain.
  enabledDomains =
    lib.unique
    (lib.mapAttrsToList (_: s: s.domain)
      (lib.filterAttrs (_: s: (s.enable or false) && (s ? domain)) config.fortress.services));

  # The split-horizon answers. Unknown names keep forwarding upstream
  # through dnsmasq's default resolv.conf handling: LAN clients use this
  # as their ONLY resolver, so it has to resolve the whole internet, not
  # just the service tree.
  dnsAddresses =
    lib.optionals (cfg.dns.enable && cfg.lanAddress != null) (
      # Firefox DoH canary: NXDOMAIN makes Firefox drop
      # "Secure DNS" on this network (RFC 8764-ish precedent).
      ["/use-application-dns.net/"]
      # baseDomain first: it is the shared path-routing origin
      # (ADR-034) every `/<path>` URL hangs off, so the LAN
      # must resolve it like any service hostname.
      ++ lib.optional (baseDomain != null) "/${baseDomain}/${cfg.lanAddress}"
      ++ map (d: "/${d}/${cfg.lanAddress}") enabledDomains
    );

  dnsConfigFile = pkgs.writeText "fortress-dnsmasq.conf" (
    lib.concatStringsSep "\n" (
      [
        "listen-address=${toString cfg.lanAddress}"
        "bind-interfaces"
        "no-hosts"
      ]
      ++ map (a: "address=${a}") dnsAddresses
    )
  );
in {
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
        Run the LAN DNS layer (fortress-dns) serving every enabled
        service's domain with `lanAddress`. Defaults to true when
        `fortress.network.lanAddress` is set.
      '';
    };

    dns.addresses = mkOption {
      type = types.listOf types.str;
      internal = true;
      default = dnsAddresses;
      description = ''
        The `address=` answers fortress-dns serves, derived from
        `lanAddress` + the enabled service tree. Internal: the wiring
        tests assert on this so a dropped service surfaces as a
        missing answer rather than a silent LAN outage.
      '';
    };

    caddyBindAddresses = mkOption {
      type = types.listOf types.str;
      internal = true;
      default = ["0.0.0.0" "::"];
      description = ''
        Addresses every fortress Caddy vhost binds. Wildcard: Caddy
        listens on every interface (LAN, tailnet, tunnel), so a new
        interface needs no config edit — the explicit localhost+LAN
        list silently bound localhost only when `lanAddress` was
        unset, which is the amon-sul cutover failure (2026-10-07).
        The bind list was never the security boundary: the firewall
        gates 80/443 and per-plane `remote_ip` allowlists add policy.
        A bare wildcard is deliberate short-term debt — the allowlist
        lands in the next few releases (see the ADR-034 amendment).
        The tunnel forwarder no longer collides because it listens on
        a distinct client port (the control plane's port map), not
        :80/:443 on the tunnel IP.
      '';
    };
  };

  config = lib.mkMerge [
    # Auto-activation outside the mkIf — the gate itself must not be
    # defined inside its own gate.
    {fortress.network.dns.enable = lib.mkDefault (cfg.lanAddress != null);}

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
            ${toString cfg.lanAddress} — the box would forward upstream
            queries to its own fortress-dns (resolver loop), and every
            non-service name would hang.
          '';
        }
      ];

      networking.firewall.allowedTCPPorts = [53];
      networking.firewall.allowedUDPPorts = [53];

      systemd.services.fortress-dns = {
        description = "fortress LAN DNS — split-horizon answers for the service tree";
        # Both this and Caddy bind concrete addresses DHCP may deliver
        # late; a start-before-address race shows up as a failed bind.
        after = ["network-online.target"];
        wants = ["network-online.target"];
        wantedBy = ["fortress.target"];
        serviceConfig = {
          # No persistent files, so no stable UID is required: DynamicUser
          # means the host never has to create an account — which the
          # applier cannot do anyway (the OS owns /etc/passwd). dnsmasq
          # skips its own privilege drop unless started as root, so the
          # dynamic identity holds for the life of the process.
          DynamicUser = true;
          AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
          CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
          # dnsmasq insists on a pidfile when it believes it is root, and dies
          # (exit 3) if it cannot write one. A writable dir here keeps the unit
          # correct whether or not the dynamic identity actually applied.
          RuntimeDirectory = "fortress-dns";
          ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --log-facility=- --pid-file=/run/fortress-dns/dnsmasq.pid --conf-file=${dnsConfigFile}";
          Restart = "on-failure";
          # A bind can lose the race to DHCP handing the address out; retry on a
          # human timescale instead of exhausting the start limit in a second.
          RestartSec = 5;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_NETLINK"];
        };
      };

      systemd.services.caddy = lib.mkIf config.services.caddy.enable {
        after = ["network-online.target"];
        wants = ["network-online.target"];
      };
    })
  ];
}
