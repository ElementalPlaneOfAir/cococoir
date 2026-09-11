# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress customer config — the dashboard-edited file.
#
# This file is the entire customer-facing configuration surface. It is a
# bare attrset, so it never needs `pkgs` or a function header: the machine
# config that imports it composes this with the fortress modules. Long-tail
# needs (custom packages, extra modules) belong in that machine config's
# `imports`, not here.
#
# The dashboard (src/dashboard/) reads and edits exactly the fields below.
# Hand-edits are fine too — the dashboard rewrites only the spans it knows
# and preserves everything else byte-for-byte.
{
  # Apex domain. Services derive their subdomains from it
  # (jellyfin.<baseDomain>, auth.<baseDomain>, ...).
  fortress.baseDomain = "vmtest.local";

  # Machine hostname.
  networking.hostName = "vmtest";

  # Service toggles. Each maps to one switch in the dashboard.
  fortress.services.jellyfin.enable = true;
  fortress.services.cryptpad.enable = true;
  fortress.services.radarr.enable = true;
  fortress.services.sonarr.enable = true;
  fortress.services.lidarr.enable = true;
  fortress.services.prowlarr.enable = true;
}
