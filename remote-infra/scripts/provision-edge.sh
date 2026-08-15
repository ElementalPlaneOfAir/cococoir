#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# provision-edge.sh — bring up the edge box end to end:
#   1. generate WireGuard keypairs (if absent)
#   2. tofu init + apply (server + firewall + DNS + renders NixOS configs)
#   3. nixos-anywhere installs NixOS on the box from the flake config
#   4. scp the edge WG private key onto the box
#
# Prereqs:
#   HCLOUD_TOKEN exported (never stored in the repo)
#   opentofu, nixos-anywhere, wg in PATH (or use the repo devshell)
#
# Usage:
#   bash remote-infra/scripts/provision-edge.sh
set -euo pipefail

cd "$(dirname "$0")/.."
TOFU_DIR="tofu"
SECRETS=".secrets/wg"

command -v opentofu >/dev/null || { echo "missing opentofu"; exit 1; }
command -v nixos-anywhere >/dev/null || { echo "missing nixos-anywhere (nix run nixpkgs#nixos-anywhere)"; exit 1; }
command -v wg >/dev/null || { echo "missing wireguard-tools (wg)"; exit 1; }

echo "==> [1/4] WireGuard keys"
bash scripts/gen-wg-keys.sh

echo "==> [2/4] tofu apply"
(
  cd "$TOFU_DIR"
  opentofu init
  opentofu apply -auto-approve
)

EDGE_IPV4=$(opentofu -chdir="$TOFU_DIR" output -raw edge_ipv4)
echo "edge box IPv4: $EDGE_IPV4"

echo "==> [3/4] nixos-anywhere install"
nixos-anywhere --flake ".#edge" "root@${EDGE_IPV4}"

echo "==> [4/4] install edge WG private key"
scp -o StrictHostKeyChecking=accept-new "$SECRETS/edge.private" "root@${EDGE_IPV4}:/etc/wireguard/edge-private.key"
ssh -o StrictHostKeyChecking=accept-new "root@${EDGE_IPV4}" \
  "chmod 0600 /etc/wireguard/edge-private.key && systemctl restart wg-quick-wg0 cococoir-edge"

echo ""
echo "==> Edge box up. Next:"
echo "  DNS: point interdim.net NS records at:"
opentofu -chdir="$TOFU_DIR" output -json nameservers | jq -r '.[] | "    \(.)"'
echo "  Customer box: apply remote-infra/nix/example123.nix on the home machine,"
echo "  then scp remote-infra/.secrets/wg/customer.private to /etc/wireguard/example123-private.key there."
