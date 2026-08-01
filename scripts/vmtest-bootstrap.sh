#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# vmtest-bootstrap.sh — verify a cococoir vmtest VM: check that
# Dex and Jellyfin are running, Dex OIDC discovery responds, and
# the test admin user can authenticate.
#
# Usage:
#   nix shell nixpkgs#sshpass --command bash vmtest-bootstrap.sh
set -euo pipefail

SSH_PORT=2222

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

command -v sshpass >/dev/null 2>&1 || {
  red "missing sshpass — run: nix shell nixpkgs#sshpass --command bash $0"
  exit 1
}

SPASS=(sshpass -p password)
SSH=(ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "$SSH_PORT" root@localhost)

echo "Waiting for SSH on port $SSH_PORT..."
for i in $(seq 1 60); do
  if "${SPASS[@]}" "${SSH[@]}" 'echo ready' 2>/dev/null; then break; fi
  sleep 2
done
echo ""

VMSH=$(mktemp)
chmod +x "$VMSH"
trap 'rm -f "$VMSH"' EXIT

cat >"$VMSH" <<'ENDOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

G='\033[32m' R='\033[31m' N='\033[0m'
fails=0
fail() { fails=$((fails + 1)); printf "  %-40s ${R}%s${N}\n" "$1" "$2"; }
pass() { printf "  %-40s ${G}%s${N}\n" "$1" "$2"; }

echo "─── Services ───"
for svc in dex cococoir-jellyfin-oidc-secret jellyfin \
  cococoir-jellarr-api-key jellarr-api-key-bootstrap jellarr \
  cococoir-cryptpad-oidc-secret cryptpad; do
  state=$(systemctl is-active $svc.service 2>/dev/null || echo missing)
  case "$state" in
    active|activating) pass "$svc" "$state" ;;
    inactive)
      # Oneshots (seed/secret/api-key units) are done when they
      # ran and exited 0.
      rc=$(systemctl show $svc.service -p ExecMainStatus --value 2>/dev/null || echo 1)
      entered=$(systemctl show $svc.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
      if [ "$entered" != "0" ] && [ "$rc" = "0" ]; then
        pass "$svc" "done"
      else
        fail "$svc" "inactive (rc=$rc)"
      fi
      ;;
    *) fail "$svc" "$state" ;;
  esac
done

# jellarr is a oneshot without RemainAfterExit: "inactive" is the
# success state, so poll ExecMainStatus instead of is-active.
# Boot path takes minutes: api-key oneshot → bootstrap (stops
# jellyfin, sleeps 10, inserts key, restarts) → jellarr run.
echo ""
echo "─── Jellarr (declarative config applied) ───"
jellarr_ok=0
for i in $(seq 1 150); do
  if systemctl is-failed -q jellarr.service \
    || systemctl is-failed -q jellarr-api-key-bootstrap.service \
    || systemctl is-failed -q cococoir-jellarr-api-key.service; then
    fail "jellarr pipeline" "FAILED"
    journalctl -u cococoir-jellarr-api-key -u jellarr-api-key-bootstrap \
      -u jellarr --no-pager -n 30 >&2 || true
    break
  fi
  status=$(systemctl show jellarr.service -p ExecMainStatus --value 2>/dev/null || echo 1)
  entered=$(systemctl show jellarr.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
  if [ "$entered" != "0" ] && [ "$status" = "0" ] \
    && [ "$(systemctl is-active jellarr.service)" = "inactive" ]; then
    jellarr_ok=1
    pass "jellarr pipeline" "applied"
    break
  fi
  sleep 2
done
[ "$jellarr_ok" = "1" ] || fail "jellarr pipeline" "timeout"

# The login page renders the branding jellarr pushed — the
# end-to-end proof that declarative config (incl. the OIDC
# integration) actually landed on the server.
if [ "$jellarr_ok" = "1" ]; then
  oidc_ok=0
  for i in $(seq 1 30); do
    if curl -sk https://jellyfin.vmtest.local/web/index.html | grep -q "Sign in with Dex"; then
      oidc_ok=1
      pass "OIDC login button" "rendered"
      break
    fi
    sleep 2
  done
  [ "$oidc_ok" = "1" ] || fail "OIDC login button" "missing"
fi

echo ""
echo "─── Health ───"
# Dex OIDC discovery
dx_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://auth.vmtest.local/dex/.well-known/openid-configuration 2>/dev/null || echo 000)
case "$dx_code" in
  200) pass "dex OIDC discovery" "$dx_code" ;;
  *)   fail "dex OIDC discovery" "$dx_code" ;;
esac

# Jellyfin health
jf_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://jellyfin.vmtest.local/health 2>/dev/null || echo 000)
case "$jf_code" in
  200) pass "jellyfin" "$jf_code" ;;
  *)   fail "jellyfin" "$jf_code" ;;
esac

# CryptPad checkup
cp_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://cryptpad.vmtest.local/checkup/ 2>/dev/null || echo 000)
case "$cp_code" in
  200) pass "cryptpad" "$cp_code" ;;
  *)   fail "cryptpad" "$cp_code" ;;
esac

echo ""
echo "─── CryptPad SSO (fresh-boot bearer secret) ───"
# Proves SSO_AUTH_CB returns a JWT. On a broken first boot cryptpad
# never applies the generated SET_BEARER_SECRET decree to the running
# process, so this fails with "secretOrPrivateKey must have a value"
# and the /ssoauth page hangs. The cococoir-cryptpad-seed-bearer
# ExecStartPre must make it pass from the first boot.
cp_node=$(readlink -f /proc/$(systemctl show cryptpad -p MainPID --value)/exe 2>/dev/null || echo "")
if [ -n "$cp_node" ] && timeout 90 "$cp_node" /tmp/ssoauth-probe.js >/dev/null 2>&1; then
  pass "cryptpad SSO_AUTH_CB" "JWT"
else
  fail "cryptpad SSO_AUTH_CB" "no JWT"
fi

echo ""
echo "─── Storage writability (service owns its subvolume) ───"
# Subvolumes created root:root 0755 are read-only to the service's
# runtime user; any service that persists data breaks (cryptpad SSO
# hung on mkdir EACCES; jellyfin could not init metadata). The btrfs
# module chowns subvolumes to the declaring service's owner.
for pair in "cococoir-cryptpad:/data/cryptpad/data" "jellyfin:/data/jellyfin/metadata"; do
  user="${pair%%:*}"; path="${pair#*:}"
  if runuser -u "$user" -- sh -c "touch '$path/.cococoir-write-test' && rm '$path/.cococoir-write-test'" 2>/dev/null; then
    pass "$user -> $path" "writable"
  else
    fail "$user -> $path" "EACCES"
  fi
done

echo ""
echo "─── Dex test user (admin@example.com / password) ───"
TOKEN=$(curl -sk -X POST https://auth.vmtest.local/dex/token \
  -H 'Authorization: Basic dm10ZXN0LWNsaTo=' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'scope=openid profile email groups' \
  -d 'username=admin@example.com' \
  -d 'password=password' 2>/dev/null | jq -r '.access_token // empty')

if [ -n "$TOKEN" ]; then
  echo "  got access token (first 20 chars): ${TOKEN:0:20}..."
  echo ""
  echo "─── ID token claims ───"
  ID_TOKEN=$(curl -sk -X POST https://auth.vmtest.local/dex/token \
    -H 'Authorization: Basic dm10ZXN0LWNsaTo=' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password' \
    -d 'scope=openid profile email groups' \
    -d 'username=admin@example.com' \
    -d 'password=password' 2>/dev/null | jq -r '.id_token // empty')
  if [ -n "$ID_TOKEN" ]; then
    PAYLOAD=$(echo "$ID_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null || \
      python3 -c "import base64,sys; print(base64.urlsafe_b64decode(sys.stdin.read().strip() + '==').decode())" 2>/dev/null)
    echo "$PAYLOAD" | jq '{email, preferred_username, groups, name}' 2>/dev/null || echo "  (could not decode)"
  fi
else
  fail "dex password grant" "no token"
fi

echo ""
if [ "$fails" -ne 0 ]; then
  echo -e "${R}FAIL: $fails check(s) failed${N}"
  exit 1
fi
echo -e "${G}Done. All checks passed.${N}"
ENDOFSCRIPT

"${SPASS[@]}" scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$VMSH" root@localhost:/tmp/vmtest-bootstrap.sh 2>/dev/null

"${SPASS[@]}" scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$(dirname "$0")/ssoauth-probe.js" root@localhost:/tmp/ssoauth-probe.js 2>/dev/null

"${SPASS[@]}" "${SSH[@]}" 'bash /tmp/vmtest-bootstrap.sh' 2>&1
