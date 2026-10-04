#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# install.sh — the fortress installer entry point (served at /install.sh).
#
# Per PLAN.md ADR-035, fortress ships two install methods and NO Docker:
#   1. Linux (any distro, incl. NixOS): native install — system-manager
#      applies the fortress services to the host's systemd (in place).
#      OS/kernel updates are a separate, independent concern.
#   2. macOS: a single Linux VM runs the stack (system-manager inside);
#      the host is just hardware. (Windows uses the same Linux VM; this
#      bash entry point is not the Windows path.)
# The Docker container tier (ADR-030) was removed by ADR-035.
#
# This script detects the host, names the right method, and reports where
# the pieces live. The automated provisioners for the two methods are being
# rebuilt now that the Docker tier is gone; until they land, this entry
# point is honest about status rather than pretending to install.
set -euo pipefail

# ---- TUI: GUM when present, plain output otherwise --------------------
GUM=""
command -v gum >/dev/null 2>&1 && GUM=gum
hdr() {
  if [ -n "$GUM" ]; then gum style --border rounded --border-foreground 212 --padding "0 1" -- "$1"
  else printf '\n==> %s\n' "$1"; fi
}
msg() {
  if [ -n "$GUM" ]; then gum style --foreground 250 "$1"; else printf '    %s\n' "$1"; fi
}
warn() {
  if [ -n "$GUM" ]; then gum style --foreground 214 --bold "$1"; else printf '    WARN: %s\n' "$1" >&2; fi
}
die() {
  if [ -n "$GUM" ]; then gum style --foreground 203 --bold "$1" || true; fi
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

# ---- OS detection -----------------------------------------------------
detect_os() {
  if [ "$(uname -s)" = "Darwin" ]; then echo macos
  elif [ -f /etc/NIXOS ] || grep -qs '^ID=nixos$' /etc/os-release 2>/dev/null; then echo nixos
  elif [ "$(uname -s)" = "Linux" ]; then echo linux
  else echo unknown
  fi
}
OS="$(detect_os)"
[ "$OS" = unknown ] && die "Unsupported host — fortress runs natively on Linux and in a Linux VM on macOS/Windows."

hdr "Fortress installer — detected: $OS"

case "$OS" in
  nixos|linux)
    hdr "Install method: Linux native"
    msg "system-manager applies the fortress services to the host's systemd"
    msg "(in place — no reboot). OS/kernel updates are handled separately."
    ;;
  macos)
    hdr "Install method: macOS/Linux VM"
    msg "A single Linux VM runs the fortress stack (system-manager inside);"
    msg "macOS is just hardware. Nix/systemd do not run on the macOS host."
    ;;
esac

hdr "Status"
warn "The automated provisioner for this method is being rebuilt (the Docker"
warn "container tier was removed by PLAN.md ADR-035). Until it lands, the"
warn "pieces are:"
msg "  - config magic-folder generator: scripts/fortress-bootstrap.sh"
msg "  - install methods + rationale:    PLAN.md ADR-035"
msg "  - docs:                           https://proletariat.tech/docs"
warn "Nothing was installed or changed on this host."
