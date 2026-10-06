#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# smtest-e2e.sh — the ADR-035 runtime proof.
#
# Boots `nixosConfigurations.smtest`: NixOS owns the machine (boot + ssh), and
# a boot trampoline runs `fortress-apply` against a magic folder on disk —
# amon-sul's exact two-lifecycle topology. It then proves four things:
#
#   1. fortress comes up (Dex serves OIDC discovery);
#   2. the OS closure does NOT contain the fortress service closure — the
#      applied Dex unit is not in `nix-store -qR /run/current-system`;
#   3. the LAN DNS plane answers from the applied closure (fortress-dns
#      resolves the service tree + baseDomain, NXDOMAINs the DoH canary);
#   4. a runtime `config.nix` edit + `fortress-apply` changes the running
#      service (Dex moves to the new port) with NO nixos-rebuild.
#
# Eval checks prove the config is well-formed; only a fresh boot proves the
# applier works. Run it before claiming any change under `nix/system-manager/`
# or `nixosConfigurations/smtest.nix` works.
#
# Usage: bash scripts/smtest-e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SSHPASS="${SSHPASS:-password}"
SSH="sshpass -p $SSHPASS ssh -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@localhost"
BOOT_TIMEOUT=180
DEX_TIMEOUT=180

echo "==> Killing any stale smtest VM (holds port 2223)"
for stale in $(pgrep -f 'qemu-system.*smtest' 2>/dev/null || true); do
  kill -9 "$stale" 2>/dev/null || true
done
wait 2>/dev/null || true
rm -f smtest.qcow2

echo "==> Building VM"
nix build --out-link /tmp/smvm .#nixosConfigurations.smtest.config.system.build.vm

# Realise the magic-folder closure on the host so the VM (shared store) does
# not download or rebuild it — only the small edited-config delta is built
# inside the VM. Without this the VM would fetch system-manager's Rust-built
# pieces from cache.nixos.org on every boot. The fixture has no lock yet (nix
# writes one on first build), so build from a writable copy.
fixture=$(nix-store -qR /tmp/smvm | grep -E -- '-fortress-magic-folder$' | head -1)
if [ -z "$fixture" ]; then
  echo "FAIL: could not find the magic-folder fixture in the VM closure" >&2
  exit 1
fi
echo "==> Pre-building the magic-folder closure on the host"
rm -rf /tmp/smtest-fixture
cp -r "$fixture" /tmp/smtest-fixture
chmod -R u+w /tmp/smtest-fixture
nix build --no-link /tmp/smtest-fixture#systemConfigs.fortress.unitsDir

echo "==> Booting VM (headless, KVM)"
/tmp/smvm/bin/run-smtest-vm -nographic > /tmp/smvm.log 2>&1 &
VM_PID=$!
cleanup() {
  kill -9 "$VM_PID" 2>/dev/null || true
  wait "$VM_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Waiting for ssh (max ${BOOT_TIMEOUT}s)"
ssh_up=""
for _ in $(seq 1 $((BOOT_TIMEOUT / 2))); do
  if $SSH 'true' 2>/dev/null; then
    ssh_up=1
    break
  fi
  sleep 2
done
if [ -z "$ssh_up" ]; then
  echo "FAIL: ssh never came up on port 2223" >&2
  tail -30 /tmp/smvm.log >&2 || true
  exit 1
fi

wait_discovery() {
  local port="$1" out=""
  for _ in $(seq 1 $((DEX_TIMEOUT / 2))); do
    out=$($SSH "curl -sf http://127.0.0.1:${port}/dex/.well-known/openid-configuration" 2>/dev/null) && {
      echo "$out"
      return 0
    }
    sleep 2
  done
  return 1
}

echo "==> [1/4] Waiting for Dex OIDC discovery on :5556 (max ${DEX_TIMEOUT}s)"
if ! discovery=$(wait_discovery 5556); then
  echo "FAIL: Dex discovery did not respond on :5556" >&2
  $SSH 'systemctl status fortress-apply dex --no-pager -n 60' >&2 || true
  exit 1
fi
echo "    issuer: $(echo "$discovery" | tr ',' '\n' | sed -n 's/.*"issuer"[^"]*"\([^"]*\)".*/\1/p' | head -1)"

echo "==> [2/4] Asserting the OS closure does NOT contain the fortress closure"
dex_unit=$($SSH 'readlink -f /run/systemd/system/dex.service')
if [ -z "$dex_unit" ]; then
  echo "FAIL: /run/systemd/system/dex.service does not resolve" >&2
  exit 1
fi
echo "    applied dex unit: $dex_unit"
if $SSH "nix-store -qR /run/current-system | grep -qxF '${dex_unit}'"; then
  echo "FAIL: the fortress service closure is IN the NixOS closure — coupled!" >&2
  exit 1
fi
echo "    not in /run/current-system — decoupled from nixos-rebuild"

echo "==> [3/4] LAN DNS: fortress-dns answers the service tree from the applied closure"
lan="10.0.2.15"
$SSH 'systemctl show fortress-dns -p User -p DynamicUser -p MainPID --value' | sed 's/^/    /' || true
dns_answer() {
  $SSH "dig +short @${lan} $1 2>/dev/null" | tr -d '\n' || true
}
resolved=""
for _ in $(seq 1 15); do
  resolved=$(dns_answer dex.example.com)
  [ "$resolved" = "$lan" ] && break
  sleep 2
done
if [ "$resolved" != "$lan" ]; then
  echo "FAIL: dex.example.com did not resolve to ${lan} via fortress-dns" >&2
  $SSH 'journalctl -u fortress-dns -b -o cat --no-pager | tail -20' >&2 || true
  $SSH 'systemctl status fortress-dns --no-pager -n 15' >&2 || true
  exit 1
fi
echo "    dex.example.com -> ${lan}"
if [ "$(dns_answer example.com)" != "$lan" ]; then
  echo "FAIL: example.com (the shared path-routing origin) did not resolve to ${lan}" >&2
  exit 1
fi
echo "    example.com -> ${lan}"
if [ -n "$(dns_answer use-application-dns.net)" ]; then
  echo "FAIL: the Firefox DoH canary answered — it must NXDOMAIN or Secure-DNS" >&2
  echo "      browsers bypass the split-horizon entirely" >&2
  exit 1
fi
echo "    use-application-dns.net -> NXDOMAIN (DoH canary)"

proc_status=$($SSH 'cat /proc/$(systemctl show -p MainPID --value fortress-dns)/status 2>/dev/null' || true)
uid=""
if [[ "$proc_status" =~ Uid:[[:space:]]*([0-9]+) ]]; then uid="${BASH_REMATCH[1]}"; fi
echo "    fortress-dns runs as uid=${uid:-unknown}"
if [ "$uid" = "0" ] || [ -z "$uid" ]; then
  echo "FAIL: fortress-dns runs as root — DynamicUser did not take effect." >&2
  echo "      A named OS user is not portable (the applier cannot create one), so" >&2
  echo "      root and DynamicUser are the only portable identities — and this" >&2
  echo "      service is stateless, so it must get the dynamic one." >&2
  exit 1
fi

echo "==> [4/4] Runtime update: move Dex to :5557 and re-apply (no nixos-rebuild)"
$SSH 'cat > /etc/fortress/config/config.nix <<"EOF"
{...}: {
  nixpkgs.hostPlatform = "x86_64-linux";
  fortress.baseDomain = "example.com";
  fortress.storage.backend = "plain-dirs";
  fortress.network.lanAddress = "10.0.2.15";
  fortress.services.dex = {
    enable = true;
    public = false;
    port = 5557;
  };
}
EOF'
$SSH 'fortress-apply /etc/fortress/config' || {
  echo "FAIL: fortress-apply failed on the edited config" >&2
  $SSH 'fortress-apply /etc/fortress/config' >&2 || true
  exit 1
}
if ! updated=$(wait_discovery 5557); then
  echo "FAIL: Dex did not move to :5557 after re-apply" >&2
  $SSH 'systemctl status dex --no-pager -n 60' >&2 || true
  exit 1
fi
echo "    Dex now on :5557 — updated without nixos-rebuild"

stamp="Last smtest e2e: PASS — $(date +%F) — $(git rev-parse --short HEAD)"
echo "==> SMTEST E2E PASS (${stamp})"
