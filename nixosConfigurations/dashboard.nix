# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir customer config — the dashboard-edited file.
#
# This file is the entire customer-facing configuration surface. It is a
# bare attrset, so it never needs `pkgs` or a function header: the machine
# config that imports it composes this with the cococoir modules. Long-tail
# needs (custom packages, extra modules) belong in that machine config's
# `imports`, not here.
#
# The dashboard (src/dashboard/) reads and edits exactly the fields below.
# Hand-edits are fine too — the dashboard rewrites only the spans it knows
# and preserves everything else byte-for-byte.
{
  # Apex domain. Services derive their subdomains from it
  # (jellyfin.<baseDomain>, auth.<baseDomain>, ...).
  cococoir.baseDomain = "vmtest.local";

  # Machine hostname.
  networking.hostName = "vmtest";

  # Service toggles. Each maps to one switch in the dashboard.
  cococoir.services.jellyfin.enable = true;
  cococoir.services.cryptpad.enable = true;
  cococoir.services.radarr.enable = true;
  cococoir.services.sonarr.enable = true;
  cococoir.services.lidarr.enable = true;
  cococoir.services.prowlarr.enable = true;
}
