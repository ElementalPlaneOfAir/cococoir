#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# gen-wg-keys.sh — generate the WireGuard keypairs for the edge box
# and the customer box into remote-infra/.secrets/wg/ (gitignored).
#
# Idempotent: if both keypairs exist, does nothing. Re-run after
# `rm -rf .secrets/wg` to rotate.
#
# The PUBLIC halves are what tofu reads and renders into the NixOS
# configs; the PRIVATE halves are scp'd to the boxes at provision
# time and never touch the repo.
set -euo pipefail

cd "$(dirname "$0")/.."
DIR=".secrets/wg"
mkdir -p "$DIR"

for role in edge customer; do
  priv="$DIR/$role.private"
  pub="$DIR/$role.pub"
  if [[ ! -f "$priv" || ! -f "$pub" ]]; then
    umask 077
    echo "generating WireGuard keypair for $role..."
    wg genkey > "$priv"
    wg pubkey < "$priv" > "$pub"
  else
    echo "$role keypair already present"
  fi
done

echo ""
echo "WireGuard public keys (already wired via tofu):"
echo "  edge     $(cat "$DIR/edge.pub")"
echo "  customer $(cat "$DIR/customer.pub")"
echo ""
echo "Private keys (do NOT commit): $PWD/$DIR/{edge,customer}.private"
