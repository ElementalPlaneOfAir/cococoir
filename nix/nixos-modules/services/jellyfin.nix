# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — jellyfin service placeholder.
#
# v0 (Day 3-4): just declare the option slot. Real config (port bind,
# FUSE mount, Caddy vhost, OIDC client) lands in Day 9-10.
#
# v0 convention: the tenant module declares the service slot via
# `cococoir.tenant.<name>.services.jellyfin.{domain,bucket}`. This
# file is a placeholder that signals "jellyfin is part of the known
# service set" — adding a new service means also adding it to
# tenant.nix's derivation. We don't yet re-export options here; the
# service module will grow into its real shape in Day 9-10.
{lib, ...}: {
  # Intentionally empty for v0. The slot is declared in tenant.nix.
  # This file exists so adding a service has a discoverable location
  # and so future imports (OIDC client creation, etc.) have a home.
  options.cococoir.services.jellyfin.docs = lib.mkOption {
    type = lib.types.attrs;
    default = {
      upstream = "https://jellyfin.org";
      defaultPort = 8096;
      notes = "Real config lands in Day 9-10.";
    };
    description = "Internal documentation for the jellyfin service module. Not customer-facing.";
    internal = true;
  };
}
