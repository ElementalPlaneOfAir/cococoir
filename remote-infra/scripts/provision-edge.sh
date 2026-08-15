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
#   HCLOUD_TOKEN exported, OR the token file at
#   ${HETZNER_TOKEN_FILE:-/home/nicole/.secrets/HETZNER_SECRET_API_KEY}
#   (read here, never stored in the repo)
#   opentofu, nixos-anywhere, wg in PATH (or use the repo devshell)
#
# Usage:
#   bash remote-infra/scripts/provision-edge.sh
set -euo pipefail

cd "$(dirname "$0")/.."
TOFU_DIR="tofu"
SECRETS=".secrets/wg"
TOKEN_FILE="${HETZNER_TOKEN_FILE:-/home/nicole/.secrets/HETZNER_SECRET_API_KEY}"

command -v tofu >/dev/null || command -v opentofu >/dev/null \
  || { echo "missing opentofu (the 'tofu' binary)"; exit 1; }
TOFU=$(command -v tofu || command -v opentofu)
command -v nixos-anywhere >/dev/null || { echo "missing nixos-anywhere (nix run nixpkgs#nixos-anywhere)"; exit 1; }
command -v wg >/dev/null || { echo "missing wireguard-tools (wg)"; exit 1; }

# The hcloud provider reads HCLOUD_TOKEN. If it's not already exported,
# pull it from the operator's token file (kept out of the repo).
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  if [[ -s "$TOKEN_FILE" ]]; then
    export HCLOUD_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
  else
    echo "missing HCLOUD_TOKEN (export it or create $TOKEN_FILE)"; exit 1
  fi
fi

echo "==> [1/4] WireGuard keys"
bash scripts/gen-wg-keys.sh

echo "==> [2/4] tofu apply"
(
  cd "$TOFU_DIR"
  "$TOFU" init
  "$TOFU" apply -auto-approve
)

EDGE_IPV4=$("$TOFU" -chdir="$TOFU_DIR" output -raw edge_ipv4)
echo "edge box IPv4: $EDGE_IPV4"

echo "==> [3/4] nixos-anywhere install"
nixos-anywhere --flake ".#edge" "root@${EDGE_IPV4}"

echo "==> [4/4] install edge WG private key"
# The box just rebooted into NixOS; SSH can take a while to come up.
# Wait (bounded) for it instead of racing the boot.
echo "    waiting for SSH on $EDGE_IPV4..."
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      -o BatchMode=yes "root@${EDGE_IPV4}" true 2>/dev/null; then
    echo "    SSH up after ${i} attempts"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "    ERROR: SSH did not come up within 300s" >&2
    exit 1
  fi
  sleep 10
done
scp -o StrictHostKeyChecking=accept-new "$SECRETS/edge.private" "root@${EDGE_IPV4}:/etc/wireguard/edge-private.key"
ssh -o StrictHostKeyChecking=accept-new "root@${EDGE_IPV4}" \
  "chmod 0600 /etc/wireguard/edge-private.key && systemctl restart wg-quick-wg0 cococoir-edge"

echo ""
echo "==> Edge box up. Next:"
echo "  DNS: point interdim.net NS records at:"
"$TOFU" -chdir="$TOFU_DIR" output -json nameservers | jq -r '.[] | "    \(.)"'
echo "  Customer box: apply remote-infra/nix/example123.nix on the home machine,"
echo "  then scp remote-infra/.secrets/wg/customer.private to /etc/wireguard/example123-private.key there."
