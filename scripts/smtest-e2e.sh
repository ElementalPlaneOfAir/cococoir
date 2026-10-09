#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# smtest-e2e.sh — the ADR-035 runtime proof.
#
# Boots `nixosConfigurations.smtest`: NixOS owns the machine (boot + ssh), and
# a boot trampoline runs `fortress-apply` against a magic folder on disk —
# amon-sul's exact two-lifecycle topology. It then proves six things:
#
#   1. fortress comes up (Dex serves OIDC discovery);
#   1b. Caddy (the ingress) is active under the applier and fronts Dex — the
#      applier creates no `caddy` account and writes no /etc config itself;
#   2. the OS closure does NOT contain the fortress service closure — the
#      applied Dex unit is not in `nix-store -qR /run/current-system`;
#   3. the LAN DNS plane answers from the applied closure (fortress-dns
#      resolves the service tree + baseDomain, NXDOMAINs the DoH canary);
#   4. a runtime `config.nix` edit + `fortress-apply` changes the running
#      service (Dex moves to the new port) with NO nixos-rebuild;
#   5. the packaged `fortress-bootstrap` generates the magic folder on-box and
#      is idempotent (the first-boot half, exercised in a scratch dir);
#   6. fortress SURVIVES A REBOOT with no manual apply — the trampoline
#      re-applies because the applier installs into tmpfs /run/systemd/system.
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
# Root the build result AND the folder's own store copy. The host runs
# nix-gc.timer, and `/tmp/smvm` is not a registered root, so both were
# collectible: the guest store is only an overlay over the host store, so when
# the host collected the folder's copy the rebooted guest lost it too (seen
# 2026-10-06). A registered gcroot under ~/.local/state/nix/gcroots survives GC.
gcroots="${XDG_STATE_HOME:-$HOME/.local/state}/nix/gcroots"
mkdir -p "$gcroots"
nix build --out-link "$gcroots/smtest-fixture" /tmp/smtest-fixture#systemConfigs.fortress.unitsDir
fixture_src="$(nix flake metadata /tmp/smtest-fixture 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^Path:[[:space:]]*//p' | head -1)"
if [ -n "$fixture_src" ]; then
  ln -sfn "$fixture_src" "$gcroots/smtest-fixture-src"
fi

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

echo "==> [1/6] Waiting for Dex OIDC discovery on :5556 (max ${DEX_TIMEOUT}s)"
if ! discovery=$(wait_discovery 5556); then
  echo "FAIL: Dex discovery did not respond on :5556" >&2
  $SSH 'systemctl status fortress-apply dex --no-pager -n 60' >&2 || true
  exit 1
fi
echo "    issuer: $(echo "$discovery" | tr ',' '\n' | sed -n 's/.*"issuer"[^"]*"\([^"]*\)".*/\1/p' | head -1)"

echo "==> [1b/6] Caddy (ingress) is active under the applier and fronts Dex"
# The fixture is public = true, so a public service must have pulled Caddy in.
# This is the exact seam amon-sul died on (2026-10-07): the applier cannot
# create the `caddy` account (userborn disabled) or write its /etc config, so
# a regression here shows up as `caddy.service: status=217/USER`.
if [ "$($SSH 'systemctl is-active caddy.service')" != "active" ]; then
  echo "FAIL: caddy.service is not active under the applier" >&2
  $SSH 'systemctl status caddy --no-pager -n 40' >&2 || true
  $SSH 'journalctl -u caddy -b -o cat --no-pager | tail -30' >&2 || true
  exit 1
fi
via_caddy=""
for _ in $(seq 1 15); do
  via_caddy=$($SSH "curl -sf http://10.0.2.15/dex/.well-known/openid-configuration" 2>/dev/null) && break
  sleep 2
done
if [ -z "$via_caddy" ]; then
  echo "FAIL: Dex is not reachable through Caddy on the LAN plane (http://10.0.2.15/dex)" >&2
  $SSH 'journalctl -u caddy -b -o cat --no-pager | tail -30' >&2 || true
  exit 1
fi
echo "    caddy active; Dex reachable through it (store config, no /etc)"

# The sealed inventory must actually decrypt at boot. This is the failure
# that looks like nothing: sops-nix falls back to a stubbed activation
# script under system-manager and silently writes no secrets at all, so
# every consumer starts with no credential.
for key in fortress-admin-password-hash jellarr-api-key radarr-api-key; do
  if ! $SSH "test -s /run/secrets/$key"; then
    echo "FAIL: /run/secrets/$key was not decrypted — the sealed inventory did not materialize" >&2
    $SSH 'ls -la /run/secrets 2>&1' >&2 || true
    $SSH 'systemctl status sops-install-secrets --no-pager -n 30' >&2 || true
    exit 1
  fi
done
echo "    sealed inventory decrypted at boot (/run/secrets populated)"

echo "==> [2/6] Asserting the OS closure does NOT contain the fortress closure"
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

echo "==> [3/6] LAN DNS: fortress-dns answers the service tree from the applied closure"
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

echo "==> [4/6] Runtime update: move Dex to :5557 and re-apply (no nixos-rebuild)"
$SSH 'cat > /etc/fortress/config/config.nix <<"EOF"
{...}: {
  nixpkgs.hostPlatform = "x86_64-linux";
  fortress.baseDomain = "example.com";
  fortress.storage.backend = "plain-dirs";
  fortress.network.lanAddress = "10.0.2.15";
  fortress.secrets.sopsFile = ./secrets/secrets.enc.yaml;
  fortress.services.dex = {
    enable = true;
    public = true;
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

echo "==> [5/6] fortress-bootstrap generates the magic folder on-box (idempotent)"
$SSH 'rm -rf /tmp/bootstrap-check && fortress-bootstrap --root /tmp/bootstrap-check' >/dev/null 2>&1 || {
  echo "FAIL: packaged fortress-bootstrap failed on-box" >&2
  $SSH 'fortress-bootstrap --root /tmp/bootstrap-check' >&2 || true
  exit 1
}
if ! $SSH 'test -s /tmp/bootstrap-check/system_age_keys.txt &&
  test -f /tmp/bootstrap-check/config/flake.nix &&
  test -f /tmp/bootstrap-check/config/config.nix &&
  test -f /tmp/bootstrap-check/config/secrets/secrets.enc.yaml &&
  grep -q "ENC\[" /tmp/bootstrap-check/config/secrets/secrets.enc.yaml'; then
  echo "FAIL: fortress-bootstrap did not produce the expected magic-folder layout" >&2
  $SSH 'find /tmp/bootstrap-check -maxdepth 3 -type f' >&2 || true
  exit 1
fi
key_before=$($SSH 'cat /tmp/bootstrap-check/system_age_keys.txt')
seal_before=$($SSH 'sha256sum /tmp/bootstrap-check/config/secrets/secrets.enc.yaml')
$SSH 'fortress-bootstrap --root /tmp/bootstrap-check' >/dev/null 2>&1 || true
if [ "$($SSH 'cat /tmp/bootstrap-check/system_age_keys.txt')" != "$key_before" ] ||
  [ "$($SSH 'sha256sum /tmp/bootstrap-check/config/secrets/secrets.enc.yaml')" != "$seal_before" ]; then
  echo "FAIL: a second fortress-bootstrap run changed the device key or secrets" >&2
  echo "      — it is not idempotent (it would destroy the folder on reboot)." >&2
  exit 1
fi
echo "    folder generated (device key + config + sealed secrets); re-run left both unchanged"

echo "==> [6/6] Reboot survival: fortress returns with no manual apply"
$SSH 'systemctl reboot' >/dev/null 2>&1 || true
sleep 5
ssh_dropped=""
for _ in $(seq 1 30); do
  if ! $SSH 'true' 2>/dev/null; then
    ssh_dropped=1
    break
  fi
  sleep 2
done
if [ -z "$ssh_dropped" ]; then
  echo "FAIL: ssh never dropped after the reboot command" >&2
  exit 1
fi
ssh_back=""
for _ in $(seq 1 $((BOOT_TIMEOUT / 2))); do
  if $SSH 'true' 2>/dev/null; then
    ssh_back=1
    break
  fi
  sleep 2
done
if [ -z "$ssh_back" ]; then
  echo "FAIL: ssh did not return after reboot" >&2
  tail -30 /tmp/smvm.log >&2 || true
  exit 1
fi
if ! wait_discovery 5557 >/dev/null; then
  echo "FAIL: after reboot fortress did NOT come back — the trampoline is broken" >&2
  echo "      (ADR-037: the applier installs into tmpfs, so it MUST re-apply on boot)." >&2
  $SSH 'systemctl status fortress-apply fortress-bootstrap dex --no-pager -n 60' >&2 || true
  $SSH 'journalctl -u fortress-apply -b -o cat --no-pager | tail -30' >&2 || true
  exit 1
fi
echo "    fortress re-applied on boot; Dex on :5557 again with no manual apply"
if [ "$($SSH 'systemctl is-active caddy.service')" != "active" ] ||
  ! $SSH "curl -sf http://10.0.2.15/dex/.well-known/openid-configuration" >/dev/null 2>&1; then
  echo "FAIL: Caddy did not come back after reboot — the public entry point is dead" >&2
  $SSH 'systemctl status caddy fortress-apply --no-pager -n 40' >&2 || true
  exit 1
fi
echo "    caddy back after reboot too"

stamp="Last smtest e2e: PASS — $(date +%F) — $(git rev-parse --short HEAD)"
echo "==> SMTEST E2E PASS (${stamp})"
