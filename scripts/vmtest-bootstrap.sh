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

echo "─── Services ───"
for svc in dex cococoir-jellyfin-oidc-secret jellyfin jellarr; do
  state=$(systemctl is-active $svc.service 2>/dev/null || echo missing)
  case "$state" in
    active|activating) printf "  %-40s ${G}%s${N}\n" "$svc" "$state" ;;
    *)                 printf "  %-40s ${R}%s${N}\n" "$svc" "$state" ;;
  esac
done

echo ""
echo "─── Health ───"
# Dex OIDC discovery
dx_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://auth.vmtest.local/dex/.well-known/openid-configuration 2>/dev/null || echo 000)
case "$dx_code" in
  200) printf "  %-25s ${G}%s${N}\n" "dex OIDC discovery" "$dx_code" ;;
  *)   printf "  %-25s ${R}%s${N}\n" "dex OIDC discovery" "$dx_code" ;;
esac

# Jellyfin health
jf_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://jellyfin.vmtest.local/health 2>/dev/null || echo 000)
case "$jf_code" in
  200) printf "  %-25s ${G}%s${N}\n" "jellyfin" "$jf_code" ;;
  *)   printf "  %-25s ${R}%s${N}\n" "jellyfin" "$jf_code" ;;
esac

echo ""
echo "─── Dex test user (admin@vmtest.local / password) ───"
TOKEN=$(curl -sk -X POST https://auth.vmtest.local/dex/token \
  -H 'Authorization: Basic amVsbHlmaW46' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'scope=openid profile email groups' \
  -d 'username=admin@vmtest.local' \
  -d 'password=password' 2>/dev/null | jq -r '.access_token // empty')

if [ -n "$TOKEN" ]; then
  echo "  got access token (first 20 chars): ${TOKEN:0:20}..."
  echo ""
  echo "─── ID token claims ───"
  ID_TOKEN=$(curl -sk -X POST https://auth.vmtest.local/dex/token \
    -H 'Authorization: Basic amVsbHlmaW46' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password' \
    -d 'scope=openid profile email groups' \
    -d 'username=admin@vmtest.local' \
    -d 'password=password' 2>/dev/null | jq -r '.id_token // empty')
  if [ -n "$ID_TOKEN" ]; then
    PAYLOAD=$(echo "$ID_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null || \
      python3 -c "import base64,sys; print(base64.urlsafe_b64decode(sys.stdin.read().strip() + '==').decode())" 2>/dev/null)
    echo "$PAYLOAD" | jq '{email, preferred_username, groups, name}' 2>/dev/null || echo "  (could not decode)"
  fi
else
  echo "  ${R}failed to get token${N} (dex may still be starting)"
fi

echo ""
echo -e "${G}Done.${N}"
ENDOFSCRIPT

"${SPASS[@]}" scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$VMSH" root@localhost:/tmp/vmtest-bootstrap.sh 2>/dev/null

"${SPASS[@]}" "${SSH[@]}" 'bash /tmp/vmtest-bootstrap.sh' 2>&1
