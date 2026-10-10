# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/_pin-arr — converge an *arr's config.xml before start.
#
# Shared by radarr.nix and sonarr.nix. The *arrs own config.xml and rewrite
# it on every settings save, so nothing here may assume the file is ours:
# every value is converged on each start, never created once. (A
# config.xml carried over from a migration kept `AuthenticationMethod=Forms`
# forever because the old script only pinned ApiKey and UrlBase — and then
# served a login page no one had credentials for.)
#
# Two of the values are security-relevant:
#
#   AuthenticationMethod   External — the app's own login is disabled and
#                          the Dex gate (caddy `forward_auth`) is the only
#                          thing between a LAN client and the app. Same
#                          handler as `None` (Servarr, Sonarr#5252): whoever
#                          reaches the port gets in. Valid ONLY while the
#                          gate is up, which _contract.nix asserts.
#   AuthenticationRequired Enabled  — mandatory attribute; moot under
#                          External but the app refuses to start without it.
#
# Tags are replaced in place if present and inserted if absent. A duplicate
# tag is harmless: the *arr uses the topmost and rewrites the file down to a
# single entry on the next save.
#
# `install` deliberately does NOT pass -o/-g: nixpkgs' hardening sets
# CapabilityBoundingSet= (empty), so a uid-0 unit has no CAP_CHOWN and
# `install -o root` dies with "Operation not permitted" even on a
# root-owned dir. The unit runs as root, so the dirs come out root-owned
# anyway; StateDirectory= guarantees they exist.
{
  pkgs,
  # Directory holding config.xml, e.g. /var/lib/radarr/.config/Radarr
  dataDir,
  # Path to the sops-decrypted API key
  apiKeySecretPath,
  # The public path prefix (UrlBase), e.g. /radarr
  urlBase,
}:
pkgs.writeShellScript "pin-arr-config" ''
  set -euo pipefail
  f=${dataDir}/config.xml
  install -d -m 0750 ${dataDir}
  [ -f "$f" ] || printf '<Config>\n</Config>\n' > "$f"

  set_or_insert() {
    local tag=$1 value=$2
    if grep -q "<$tag>" "$f"; then
      ${pkgs.gnused}/bin/sed -i "s|<$tag>[^<]*</$tag>|<$tag>$value</$tag>|" "$f"
    else
      ${pkgs.gnused}/bin/sed -i "s|<Config>|<Config>\n    <$tag>$value</$tag>|" "$f"
    fi
  }

  set_or_insert ApiKey "$(cat ${apiKeySecretPath})"
  set_or_insert UrlBase "${urlBase}"
  set_or_insert AuthenticationMethod "External"
  set_or_insert AuthenticationRequired "Enabled"
  chown root:root "$f"
''
