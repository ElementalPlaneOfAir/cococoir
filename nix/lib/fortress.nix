# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared predicates over `config.fortress.services`.
#
# `fortress.services` mixes two kinds of entry:
#
#   * routed services — built by `mkFortressService`
#     (nix/nixos-modules/services/_contract.nix). They carry the full
#     ADR-004 contract: domain, path, port, healthUrl, journald.units.
#   * plain toggles — group switches like `media` that turn several
#     services on at once. No routing surface at all.
#
# Every module that walks the tree has to tell them apart, and there
# used to be three spellings of that test (`? domain`, `? port`,
# `? journald`) — which is exactly how a fourth consumer grows a fourth
# spelling. One predicate, one marker.
{lib}: let
  # The contract's prober surface (ADR-004) is the marker: a plain
  # toggle has no URL to GET, no path to link to, and no entry in the
  # dashboard catalog. `healthUrl` implies the rest of the contract —
  # assert it rather than let a half-built service render a broken link.
  isRoutedService = service: let
    routed = (service.enable or false) && (service ? healthUrl);
    complete = service ? path && service ? port && service ? domain;
  in
    assert lib.assertMsg (!routed || complete) ''
      a service carrying healthUrl must also carry path, port and domain
      (the ADR-004 contract). mkFortressService builds all four at once,
      so a partial one means a service bypassed the factory and the
      dashboard would render a card with no working link.
    '';
    routed;
in {
  inherit isRoutedService;

  routedServices = services: lib.filterAttrs (_: isRoutedService) services;

  routedServiceNames = services: builtins.attrNames (lib.filterAttrs (_: isRoutedService) services);

  # The dashboard catalog: one row per enabled routed service, carrying
  # exactly what a card needs — where to link (path/domain) and where to
  # probe for liveness (healthUrl). The ADR-004 contract is the single
  # source of truth; the client keeps no copy of this.
  mkCatalog = services:
    lib.mapAttrsToList (name: s: {
      inherit name;
      inherit (s) description path domain port public healthUrl;
    }) (lib.filterAttrs (_: isRoutedService) services);
}
