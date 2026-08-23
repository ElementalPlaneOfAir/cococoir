#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# provision-edge.sh — bring up the edge box end to end:
#   1. resolve secrets (secretspec, provisioning profile)
#   2. tofu init + apply (server + firewall + DNS + renders customer config)
#   3. install Nix on the stock Debian image
#   4. system-manager switch (applies remote-infra/system-manager/edge.nix)
#   5. write edge secrets (edge.env + secretspec.toml)
#   6. install the edge WG private key + wire the tunnel
#
# Secrets resolve through the secretspec CLI, pinned to 0.19 via the
# repo flake (`nix run .#secretspec`) — the devshell's `secretspec`
# comes from devenv's own nixpkgs and lacks the file provider backend.
# The provisioning profile is the single store at remote-infra/.secrets
# (gitignored); scopes carve it per consumer: `token` for tofu
# (HCLOUD_TOKEN), `provision` for edge.env (token + admin key).
#
# Prereqs:
#   nix + tofu in PATH (or use the repo devshell)
#
# Usage:
#   bash remote-infra/scripts/provision-edge.sh
set -euo pipefail

cd "$(dirname "$0")/.."
TOFU_DIR="tofu"
REPO_ROOT="$(git rev-parse --show-toplevel)"
# The standalone provisioning toml at the repo root (operator-side only),
# so the file: provider root (`./remote-infra/.secrets`) resolves against
# the repo root.
TOML="$REPO_ROOT/secretspec.toml"

command -v tofu >/dev/null || command -v opentofu >/dev/null \
  || { echo "missing opentofu (the 'tofu' binary)"; exit 1; }
TOFU=$(command -v tofu || command -v opentofu)
command -v nix >/dev/null || { echo "missing nix (nix run .#secretspec)"; exit 1; }

# Every secretspec call needs --reason (require_reason policy).
echo "==> [1/6] resolve Hetzner token (secretspec, token scope)"
eval "$(nix run "$REPO_ROOT#secretspec" -- export -P provisioning -S token \
  -f "$TOML" --format shell --reason "provision-edge: tofu apply")"
export HCLOUD_TOKEN="$HETZNER_TOKEN"

echo "==> [2/6] tofu apply"
(
  cd "$TOFU_DIR"
  "$TOFU" init
  "$TOFU" apply -auto-approve
)

EDGE_IPV4=$("$TOFU" -chdir="$TOFU_DIR" output -raw edge_ipv4)
echo "edge box IPv4: $EDGE_IPV4"

echo "==> [3/6] ensure Nix is installed on the stock Debian image"
# Idempotent: if `nix` is already on the box, skip the installer — the
# official script refuses to run on an installed Nix ("Nix already
# installed"), which is exactly the failure a re-provision hits. The
# daemon installer is required (system-manager deploy pushes closures,
# which needs the daemon's trusted-users).
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@${EDGE_IPV4}" \
  "if command -v nix >/dev/null 2>&1; then
     echo 'nix already installed; skipping installer';
   else
     sh <(curl -L --proto '=https' --tlsv1.2 https://nixos.org/nix/install) --daemon
   fi && \
   printf 'trusted-users = root\n' >> /etc/nix/nix.conf && systemctl restart nix-daemon"

echo "==> [4/6] system-manager switch (applies the edge config)"
# system-manager's own flake (pinned via our flake.lock) is the CLI;
# `--flake .#edge` resolves our repo flake because we run from the
# repo root. It builds the config locally and nix-copy-closure's it.
(
  cd "$REPO_ROOT"
  nix run 'github:numtide/system-manager' -- \
    --target-host "root@${EDGE_IPV4}" \
    switch --flake ".#edge" --sudo
)

echo "==> [5/6] write edge secrets (edge.env + secretspec.toml)"
# The edge secrets resolve through the secretspec SDK: a value-free
# secretspec.toml contract (deployed here) + a dotenv edge.env holding
# the values (zone + token + root domain + admin key hash). The SDK
# reads secretspec.toml via a CWD walk from /etc/cococoir
# (WorkingDirectory on the unit) and the values from edge.env (0600,
# never in the repo). `-S provision` = token + generated admin key.
eval "$(nix run "$REPO_ROOT#secretspec" -- export -P provisioning -S provision \
  -f "$TOML" --format shell --reason "provision-edge: write edge.env")"
DNS_ZONE_ID=$("$TOFU" -chdir="$TOFU_DIR" output -raw dns_zone_id)
DOMAIN=$("$TOFU" -chdir="$TOFU_DIR" output -raw domain)
DNS_TOKEN="$HETZNER_TOKEN"
# ADMIN_KEY is a 32-char hex string (no trailing newline). The box
# verifies sha256 of the exact presented bytes, so the hash must be of
# the exact value — a naive `sha256sum` of a newline-terminated file
# would bake the newline into the hash and reject every real key.
ADMIN_KEY_HASH=$(printf '%s' "$ADMIN_KEY" | sha256sum | cut -d' ' -f1)

# Deploy the committed contract + the values file. The plaintext admin
# key never reaches the box — it lives in the operator's secretspec
# store, retrievable with `nix run .#secretspec -- export`.
ssh -o StrictHostKeyChecking=accept-new "root@${EDGE_IPV4}" \
  "mkdir -p /etc/cococoir && \
   cat > /etc/cococoir/secretspec.toml && \
   printf 'DNS_ZONE_ID=%s\nDNS_ZONE_NAME=%s\nDNS_TOKEN=%s\nROOT_DOMAIN=%s\nADMIN_KEY_HASH=%s\n' \
     '$DNS_ZONE_ID' '${DOMAIN}' '$DNS_TOKEN' '${DOMAIN}' '$ADMIN_KEY_HASH' > /etc/cococoir/edge.env && \
   chmod 0600 /etc/cococoir/edge.env && chmod 0644 /etc/cococoir/secretspec.toml" \
  < "$REPO_ROOT/crates/controlplane/secretspec.toml"

echo "==> [6/6] wire the WG tunnel interface"
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
echo "  Admin key (for the control-plane API):"
echo "    nix run .#secretspec -- export -P provisioning -S provision --format shell"