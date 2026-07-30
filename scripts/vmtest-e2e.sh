#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# vmtest-e2e.sh — the "prove it works" button. Nukes the vmtest
# disk overlay, rebuilds the VM, boots it headless, and runs the
# full health + OIDC assertion suite (vmtest-bootstrap.sh).
#
# Why this exists: eval-time checks (nix flake check) prove the
# config is well-formed; only a fresh boot proves the stack
# actually comes up — jellarr applies config, Dex serves
# discovery, the login button renders. Run this before claiming
# any change to nix/nixos-modules "works".
#
# Usage:
#   nix shell nixpkgs#sshpass --command bash scripts/vmtest-e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Nuking vmtest disk overlay (fresh boot state)"
rm -f vmtest.qcow2

echo "==> Building VM"
nix build .#nixosConfigurations.vmtest.config.system.build.vm

echo "==> Booting VM (headless, KVM)"
./result/bin/run-vmtest-vm -nographic &
VM_PID=$!
cleanup() { kill "$VM_PID" 2>/dev/null || true; wait "$VM_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Running assertion suite"
bash scripts/vmtest-bootstrap.sh

# Self-maintaining doc: docs/STATUS.md records its own proof.
# If this line is stale, the "works" claims above it are suspect.
stamp="Last e2e: PASS — $(date +%F) — $(git rev-parse --short HEAD)"
sed -i "s|^Last e2e:.*|${stamp}|" docs/STATUS.md

echo "==> E2E PASS (${stamp})"
