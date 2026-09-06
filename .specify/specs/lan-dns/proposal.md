# LAN DNS — the dnsmasq access plane (ADR-028)

## Problem

LAN devices reach cococoir services only through the edge (`AAAA →
edge /128 → WG tunnel → box`), paying full internet transit for
traffic that never needs to leave the house, and keeping the box's
LAN-side story dependent on cococoir infra. The fix is the box
answering DNS for its own service domains with a LAN address — but
that requires (a) devices to *use* the box as resolver and (b) Caddy
to actually listen on the address the answers point at.

## Decision

Customer sets **one** thing: `cococoir.network.lanAddress` (the box's
static LAN IPv4, via a DHCP reservation) + one router DHCP-DNS
redirect to that address. Everything else derives:

- `cococoir.network.dns.enable` defaults to `lanAddress != null` —
  setting the address is the intent signal. No second toggle.
- dnsmasq (DNS only, no DHCP — the router keeps DHCP) answers every
  **enabled** service's `domain` with `lanAddress`, enumerated from
  `config.cococoir.services` — new catalog services are covered with
  zero config. All other queries forward upstream via the box's own
  resolver config. NXDOMAIN for `use-application-dns.net` (Firefox
  DoH canary) by default.
- The factory's hardcoded `bind 127.0.0.1 ::1` becomes the
  platform-internal `cococoir.network.caddyBindAddresses` (default
  `["127.0.0.1" "::1"] ++ lanAddress`), so Caddy terminates TLS on
  the LAN address too. Contract surface unchanged (no new per-service
  option; ADR-020 intact).

Split-horizon safety: the global answer (edge → tunnel) keeps
working, so the local override is an optimization with a working
fallback, not a lie. DoH bypass degrades to the tunnel path.

## Alternatives rejected

- **radvd + RDNSS (RA capture)**: RAs are IPv6-only; ~90% of target
  homes have no IPv6. No joinable capture channel exists on a v4-only
  LAN that isn't the DHCP server. Not built (ADR-028).
- **Runtime auto-derived LAN address** (auth-zone per-interface
  answers + DHCP): dnsmasq could answer dynamically, but Caddy's bind
  is render-time — there is nothing to bind. Runtime config rewriting
  is the fragile version of the same thing. Static address won.
- **dnsmasq running DHCP too**: conflicts with the router's DHCP for
  every customer who doesn't disable it first; the router redirect
  is the agreed trip, one DHCP server stays.

## Strongest objection

This couples LAN access to "the customer can make one DHCP
reservation", which fails on locked-down ISP routers where even that
is impossible. Accepted: those networks are v4-only by premise anyway
(no RA channel exists), so there is no better mechanism to offer —
the objection is about customer reach, not design shape.

## Acceptance criteria

1. `nix flake check` green including an extended `vmtest-wiring`
   (L1): every enabled vhost's rendered `extraConfig` contains
   `bind 127.0.0.1 ::1 <lanAddress>`; dnsmasq settings contain
   `/​<domain>/<lanAddress>` for every enabled service domain + the
   DoH canary; `resolveLocalQueries = false`.
2. `scripts/vmtest-e2e.sh` PASS with new checks: `dig @<lanAddress>`
   answers each service domain with `<lanAddress>`; canary
   NXDOMAINs; `curl --resolve <domain>:443:<lanAddress>` verifies the
   cert against the VM trust store and returns 200 (the full
   customer path: resolve via box DNS → connect to box LAN IP →
   trusted TLS).
3. Loop guard: eval fails if `networking.nameservers` contains
   `lanAddress`.
