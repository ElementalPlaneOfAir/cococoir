#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# provision-edge.sh — bring up the edge box end to end:
#   1. generate WireGuard keypairs (if absent)
#   2. tofu init + apply (server + firewall + DNS + renders customer config)
#   3. install Nix on the stock Debian image
#   4. system-manager switch (applies remote-infra/system-manager/edge.nix)
#   5. install the edge WG private key + wire the tunnel
#
# Prereqs:
#   HCLOUD_TOKEN exported, OR the token file at
#   ${HETZNER_TOKEN_FILE:-/home/nicole/.secrets/HETZNER_SECRET_API_KEY}
#   (read here, never stored in the repo)
#   opentofu, nix, wg in PATH (or use the repo devshell)
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
command -v nix >/dev/null || { echo "missing nix (nix run nixpkgs#system-manager)"; exit 1; }
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

echo "==> [1/5] WireGuard keys"
bash scripts/gen-wg-keys.sh

echo "==> [2/5] tofu apply"
(
  cd "$TOFU_DIR"
  "$TOFU" init
  "$TOFU" apply -auto-approve
)

EDGE_IPV4=$("$TOFU" -chdir="$TOFU_DIR" output -raw edge_ipv4)
echo "edge box IPv4: $EDGE_IPV4"

echo "==> [3/5] install Nix on the stock Debian image"
# Official single-user... no: daemon installer (system-manager deploy
# pushes closures, which needs the daemon's trusted-users).
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@${EDGE_IPV4}" \
  "sh <(curl -L --proto '=https' --tlsv1.2 https://nixos.org/nix/install) --daemon && \
   printf 'trusted-users = root\n' >> /etc/nix/nix.conf && systemctl restart nix-daemon"

echo "==> [4/5] system-manager switch (applies the edge config)"
# system-manager's own flake (pinned via our flake.lock) is the CLI;
# `--flake .#edge` resolves our repo flake because we run from the
# repo root. It builds the config locally and nix-copy-closure's it.
(
  cd "$(git rev-parse --show-toplevel)"
  nix run 'github:numtide/system-manager' -- \
    --target-host "root@${EDGE_IPV4}" \
    switch --flake ".#edge" --sudo
)

echo "==> [5/5] wire the WG tunnel interface"
# The edge box owns its WireGuard identity at runtime: cococoir-edge
# generates + persists a keypair in Redis on first boot and installs it
# into wg0 (see ControlPlane::edge_public_key). wg0.conf only needs *a*
# key for `wg-quick up` to bring the interface up; the edge overrides it
# on boot, so we generate a throwaway here. Address + listen port come
# from tofu's single source of truth.
WG_IP=$("$TOFU" -chdir="$TOFU_DIR" output -raw edge_wg_ip)         # 10.10.0.1
WG_PORT=$("$TOFU" -chdir="$TOFU_DIR" output -raw wg_listen_port 2>/dev/null || echo "51820")
ssh -o StrictHostKeyChecking=accept-new "root@${EDGE_IPV4}" \
  "wg genkey > /etc/wireguard/wg0-throwaway.key && \
   chmod 0600 /etc/wireguard/wg0-throwaway.key && \
   printf '[Interface]\nAddress = %s/24\nListenPort = %s\nPrivateKey = %s\n' \
     '$WG_IP' '$WG_PORT' \"\$(cat /etc/wireguard/wg0-throwaway.key)\" > /etc/wireguard/wg0.conf && \
   chmod 0600 /etc/wireguard/wg0.conf && rm -f /etc/wireguard/wg0-throwaway.key && \
   systemctl restart wg-quick-wg0 cococoir-edge"

echo ""
echo "==> Edge box up. Its WG public key is served by the control plane"
echo "    at https://<edge-ip>:8081/pubkey (or returned in each signup)."
echo "  DNS: point interdim.net NS records at:"
"$TOFU" -chdir="$TOFU_DIR" output -json nameservers | jq -r '.[] | "    \(.)"'
echo "  Customer box: apply remote-infra/nix/example123.nix on the home machine,"
echo "  then scp remote-infra/.secrets/wg/customer.private to /etc/wireguard/example123-private.key there."
