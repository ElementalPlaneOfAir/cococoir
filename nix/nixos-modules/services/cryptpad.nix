# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — cryptpad service placeholder.
#
# v0 (Day 3-4): just declare the option slot. Real config (port bind,
# FUSE mount, Caddy vhost, OIDC client) lands in Day 9-10.
#
# See services/jellyfin.nix for the v0 convention. The slot is
# declared in tenant.nix; this file is a discoverable home for the
# future service module.
{lib, ...}: {
  options.cococoir.services.cryptpad.docs = lib.mkOption {
    type = lib.types.attrs;
    default = {
      upstream = "https://cryptpad.org";
      defaultPort = 9123;
      notes = "Real config lands in Day 9-10.";
    };
    description = "Internal documentation for the cryptpad service module. Not customer-facing.";
    internal = true;
  };
}
