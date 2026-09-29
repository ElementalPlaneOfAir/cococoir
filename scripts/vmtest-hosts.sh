#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# vmtest-hosts.sh — temporary /etc/hosts entries for
# the fortress v2 dev VM (vmtest).
#
# The VM forwards host:4433 -> guest:443 (Caddy/TLS). Caddy
# routes by hostname to the right service. Add the
# per-service subdomains under `vmtest.local` to
# /etc/hosts so the browser can resolve the names.
#
# Usage:
#   vmtest-hosts.sh                  # add all known services
#   vmtest-hosts.sh add jellyfin     # add one or more
#   vmtest-hosts.sh add jellyfin nextcloud
#   vmtest-hosts.sh rm               # remove all
#   vmtest-hosts.sh rm jellyfin      # remove one
#   vmtest-hosts.sh list             # show the known list
#
# On NixOS hosts, /etc/hosts is read-only. The script detects
# this and prints the `networking.hosts` snippet to add to your
# NixOS configuration instead.
set -euo pipefail

# Services that exist in the vmtest VM. Add to this list as new
# service modules come online (nextcloud, gitea, ...).
KNOWN_SERVICES=(apex jellyfin radarr sonarr cryptpad seerr git auth qbittorrent)
# "apex" is the shared path-routing origin itself (vmtest.local) —
# every service is at /<name> there (ADR-034).
SUFFIX="vmtest.local"
HOSTS=/etc/hosts
MARKER="# vmtest"

entry_for() { if [ "$1" = apex ]; then echo "$SUFFIX"; else echo "$1.$SUFFIX"; fi; }

is_nixos() {
  [[ -f /etc/os-release ]] && grep -qE '^ID=nixos$' /etc/os-release
}

nixos_hint() {
  cat <<EOF >&2
This is a NixOS host — /etc/hosts is read-only. Add the entries
to your NixOS configuration instead:

  networking.hosts."127.0.0.1" = [
$(for s in "$@"; do if [ "$s" = apex ]; then echo "    \"$SUFFIX\""; else echo "    \"$s.$SUFFIX\""; fi; done)
  ];

Then nixos-rebuild switch.
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  list)
    for s in "${KNOWN_SERVICES[@]}"; do entry_for "$s"; done
    ;;
  rm|remove|undo)
    services=("$@")
    if [[ ${#services[@]} -eq 0 ]]; then
      services=("${KNOWN_SERVICES[@]}")
    fi
    if is_nixos; then
      nixos_hint "${services[@]}"
      exit 1
    fi
    removed=()
    for s in "${services[@]}"; do
      entry="$(entry_for "$s")"
      if grep -qF "$MARKER $entry" "$HOSTS"; then
        sudo sed -i "/$MARKER $entry/d" "$HOSTS"
        removed+=("$entry")
      fi
    done
    if [[ ${#removed[@]} -gt 0 ]]; then
      echo "removed: ${removed[*]}"
    else
      echo "nothing to remove"
    fi
    ;;
  add|"")
    services=("$@")
    if [[ ${#services[@]} -eq 0 ]]; then
      services=("${KNOWN_SERVICES[@]}")
    fi
    if is_nixos; then
      nixos_hint "${services[@]}"
      exit 1
    fi
    added=()
    for s in "${services[@]}"; do
      entry="$(entry_for "$s")"
      if grep -qE "[[:space:]]${entry//./\\.}([[:space:]]|$)" "$HOSTS"; then
        echo "$entry already in $HOSTS"
      else
        printf '127.0.0.1 %s %s\n' "$entry" "$MARKER" | sudo tee -a "$HOSTS" >/dev/null
        added+=("$entry")
      fi
    done
    if [[ ${#added[@]} -gt 0 ]]; then
      echo "added: ${added[*]}"
    fi
    ;;
  -h|--help|help)
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown argument: $cmd" >&2
    echo "run with no args to add, or 'rm' / 'list' / 'add <svc...>'" >&2
    exit 1
    ;;
esac
