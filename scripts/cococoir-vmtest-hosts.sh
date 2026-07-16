#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# cococoir-vmtest-hosts.sh — temporary /etc/hosts entries for
# the cococoir v2 dev VM (vmtest).
#
# The VM forwards host:4433 -> guest:443 (Caddy/TLS). Caddy
# routes by hostname to the right service. Add the
# per-service subdomains under `cococoir-vmtest.local` to
# /etc/hosts so the browser can resolve the names.
#
# Usage:
#   cococoir-vmtest-hosts.sh                  # add all known services
#   cococoir-vmtest-hosts.sh add jellyfin     # add one or more
#   cococoir-vmtest-hosts.sh add jellyfin nextcloud
#   cococoir-vmtest-hosts.sh rm               # remove all
#   cococoir-vmtest-hosts.sh rm jellyfin      # remove one
#   cococoir-vmtest-hosts.sh list             # show the known list
#
# On NixOS hosts, /etc/hosts is read-only. The script detects
# this and prints the `networking.hosts` snippet to add to your
# NixOS configuration instead.
set -euo pipefail

# Services that exist in the vmtest VM. Add to this list as new
# service modules come online (nextcloud, gitea, ...).
KNOWN_SERVICES=(jellyfin)
SUFFIX="cococoir-vmtest.local"
HOSTS=/etc/hosts
MARKER="# cococoir-vmtest"

is_nixos() {
  [[ -f /etc/os-release ]] && grep -qE '^ID=nixos$' /etc/os-release
}

nixos_hint() {
  cat <<EOF >&2
This is a NixOS host — /etc/hosts is read-only. Add the entries
to your NixOS configuration instead:

  networking.hosts."127.0.0.1" = [
$(printf '    "%s.%s"\n' "$@" "$SUFFIX" | sed 's/^/    /' | sed 's/$/"/')
  ];

Then nixos-rebuild switch.
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  list)
    printf '%s.%s\n' "${KNOWN_SERVICES[@]}" "$SUFFIX"
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
      entry="$s.$SUFFIX"
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
      entry="$s.$SUFFIX"
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
