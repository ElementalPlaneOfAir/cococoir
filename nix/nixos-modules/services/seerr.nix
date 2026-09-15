# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/seerr — media request & discovery UI (the public
# face of the media stack).
#
# 3-option contract (metadata-only service, no bucket).
#
# Design decisions (see .specify/specs/media-automation-stack/):
#   - `public = true`: Seerr is the customer-facing front door —
#     browse/search metadata, request movies and shows.
#   - Its config (settings, Jellyfin + *arr connections) lives in a
#     SQLite DB under /var/lib/seerr — not declarable — so the
#     fortress-media-apply oneshot drives it via the Seerr API at
#     boot (jellarr pattern). Seerr needs no media-file access.
#   - Upstream rename note: nixpkgs' module is services.seerr (the
#   merged Overseerr/Jellyseerr project); auth is via Jellyfin
#   accounts (generic OIDC is upstream preview-only, not stable).
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkFortressService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkFortressService {
  name = "seerr";
  description = "Seerr media request manager";
  defaultPort = 5055;
  defaultHealthPath = "/api/v1/status";
  requires = ["jellyfin"];
  extraConfig = {lib, ...}: {
    services.seerr = {
      enable = true;
      openFirewall = false;
    };
  };
}
