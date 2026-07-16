#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# add-jellyfin-hosts.sh — temporary /etc/hosts entry for the
# cococoir v2 dev VM.
#
# The VM forwards host:4433 -> guest:443 (Caddy/TLS) and
# host:2222 -> guest:22 (SSH). The browser URL
#   https://jellyfin.local:4433
# needs `jellyfin.local` to resolve to 127.0.0.1. This script
# adds and removes that entry from /etc/hosts.
#
# Usage:
#   add-jellyfin-hosts.sh         # add (idempotent)
#   add-jellyfin-hosts.sh rm      # remove our line
#
# Requires sudo (we're modifying /etc/hosts).
set -euo pipefail

HOSTS=/etc/hosts
ENTRY="127.0.0.1 jellyfin.local"
MARKER="# cococoir-v2-jellyfin"

case "${1:-}" in
  rm|remove|undo)
    if grep -qF "$MARKER" "$HOSTS"; then
      sudo sed -i "/$MARKER/d" "$HOSTS"
      echo "removed $ENTRY from $HOSTS"
    else
      echo "$ENTRY not present (no marker found)"
    fi
    ;;
  -h|--help|help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  "")
    if grep -qE "[[:space:]]jellyfin\.local([[:space:]]|$)" "$HOSTS"; then
      echo "$ENTRY already in $HOSTS"
    else
      printf '%s %s\n' "$ENTRY" "$MARKER" | sudo tee -a "$HOSTS" >/dev/null
      echo "added $ENTRY to $HOSTS"
    fi
    ;;
  *)
    echo "unknown argument: $1" >&2
    echo "run with no args to add, or 'rm' to remove" >&2
    exit 1
    ;;
esac
