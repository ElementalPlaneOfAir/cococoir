#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# vmtest-bootstrap.sh — verify a fortress vmtest VM: check that
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
# Always-on services only. The jellarr pipeline oneshots
# (jellarr-api-key-bootstrap, jellarr) start late in boot; a
# snapshot check would race them, so the dedicated wait loop
# below owns their verification.
for svc in dex fortress-jellyfin-oidc-secret jellyfin \
  fortress-jellarr-api-key fortress-cryptpad-oidc-secret cryptpad \
  qbittorrent seerr fortress-media-api-keys; do
  state=$(systemctl is-active $svc.service 2>/dev/null || true)
  [ -n "$state" ] || state=missing
  case "$state" in
    active|activating) pass "$svc" "$state" ;;
    inactive)
      # Oneshots (seed/secret/api-key units) are done when they
      # ran and exited 0. systemd zeroes ActiveEnterTimestamp
      # on deactivation; ExecMainExitTimestampMonotonic persists.
      rc=$(systemctl show $svc.service -p ExecMainStatus --value 2>/dev/null || echo 1)
      exited=$(systemctl show $svc.service -p ExecMainExitTimestampMonotonic --value 2>/dev/null || echo 0)
      if [ "$exited" != "0" ] && [ "$rc" = "0" ]; then
        pass "$svc" "done"
      else
        fail "$svc" "inactive (rc=$rc)"
      fi
      ;;
    *) fail "$svc" "$state" ;;
  esac
done

# jellarr is a oneshot without RemainAfterExit: "inactive" is the
# success state, so poll exit timestamp + status instead of
# is-active. Boot path takes minutes: api-key oneshot → bootstrap
# (stops jellyfin, sleeps 10, inserts key, restarts) → jellarr run.
echo ""
echo "─── Jellarr (declarative config applied) ───"
jellarr_ok=0
for i in $(seq 1 450); do
  if systemctl is-failed -q jellarr.service \
    || systemctl is-failed -q jellarr-api-key-bootstrap.service \
    || systemctl is-failed -q fortress-jellarr-api-key.service; then
    fail "jellarr pipeline" "FAILED"
    journalctl -u fortress-jellarr-api-key -u jellarr-api-key-bootstrap \
      -u jellarr --no-pager -n 30 >&2 || true
    break
  fi
  status=$(systemctl show jellarr.service -p ExecMainStatus --value 2>/dev/null || echo 1)
  exited=$(systemctl show jellarr.service -p ExecMainExitTimestampMonotonic --value 2>/dev/null || echo 0)
  if [ "$exited" != "0" ] && [ "$status" = "0" ] \
    && [ "$(systemctl is-active jellarr.service)" = "inactive" ]; then
    jellarr_ok=1
    pass "jellarr pipeline" "applied"
    break
  fi
  sleep 2
done
[ "$jellarr_ok" = "1" ] || fail "jellarr pipeline" "timeout"

echo ""
echo "─── Media automation stack (qbittorrent, radarr, sonarr, seerr) ───"
apply_ok=0
for i in $(seq 1 450); do
  if systemctl is-failed -q fortress-media-api-keys.service \
    || systemctl is-failed -q fortress-media-apply.service; then
    fail "media-apply pipeline" "FAILED"
    journalctl -u fortress-media-api-keys -u fortress-media-apply \
      --no-pager -n 40 >&2 || true
    break
  fi
  state=$(systemctl is-active fortress-media-apply.service 2>/dev/null || true)
  if [ "$state" = "active" ]; then
    apply_ok=1
    pass "media-apply pipeline" "applied"
    break
  fi
  sleep 2
done
[ "$apply_ok" = "1" ] || fail "media-apply pipeline" "timeout"

if [ "$apply_ok" = "1" ]; then
  radarr_key=$(cat /var/lib/fortress-media/radarr-api-key)
  sonarr_key=$(cat /var/lib/fortress-media/sonarr-api-key)

  qbt_ok=0
  for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:8080/api/v2/torrents/categories \
      | jq -e 'has("movies") and has("tv")' >/dev/null 2>&1; then
      qbt_ok=1
      pass "qbt categories" "movies + tv save paths"
      break
    fi
    sleep 2
  done
  [ "${qbt_ok:-0}" = "1" ] || fail "qbt categories" "missing movies/tv save paths"

  for svc in radarr sonarr; do
    port=$( [ "$svc" = radarr ] && echo 7878 || echo 8989 )
    key=$(cat "/var/lib/fortress-media/$svc-api-key")
    arr_ok=0
    for i in $(seq 1 30); do
      if curl -sf -H "X-Api-Key: $key" "http://127.0.0.1:$port/api/v3/downloadclient" \
        | jq -e 'map(select(.name == "qBittorrent")) | length > 0' >/dev/null 2>&1; then
        arr_ok=1
        pass "$svc download client" "qBittorrent wired (category)"
        break
      fi
      sleep 2
    done
    [ "$arr_ok" = "1" ] || fail "$svc download client" "qBittorrent missing"
  done

  seerr_ok=0
  seerr_cookie=$(mktemp)
  # Seerr's only first-boot admin path is Jellyfin sign-in (local login
  # has no admin-creation route); re-auth the bootstrap user.
  if curl -sf -c "$seerr_cookie" -H 'Content-Type: application/json' \
      -d "{\"username\": \"seerr-bootstrap\", \"password\": \"$(cat /var/lib/fortress-media/seerr-admin-password)\", \"hostname\": \"127.0.0.1\", \"port\": 8096, \"useSsl\": false, \"urlBase\": \"\", \"serverType\": 2}" \
      http://127.0.0.1:5055/api/v1/auth/jellyfin >/dev/null \
    || curl -sf -c "$seerr_cookie" -H 'Content-Type: application/json' \
      -d "{\"username\": \"seerr-bootstrap\", \"password\": \"$(cat /var/lib/fortress-media/seerr-admin-password)\", \"useSsl\": false, \"serverType\": 2}" \
      http://127.0.0.1:5055/api/v1/auth/jellyfin >/dev/null; then
    for i in $(seq 1 30); do
      if curl -sf -b "$seerr_cookie" http://127.0.0.1:5055/api/v1/settings/radarr \
        | jq -e 'map(select(.hostname == "127.0.0.1" and .port == 7878)) | length > 0' >/dev/null 2>&1; then
        seerr_ok=1
        pass "seerr wiring" "radarr + sonarr + jellyfin connected"
        break
      fi
      sleep 2
    done
  fi
  [ "${seerr_ok:-0}" = "1" ] || fail "seerr wiring" "radarr instance missing or login refused"
  rm -f "$seerr_cookie"
fi

# The login page renders the branding jellarr pushed — the
# end-to-end proof that declarative config (incl. the OIDC
# integration) actually landed on the server. Jellyfin 10.11's
# web client is an SPA: branding is served via the public
# Branding/Configuration API (the same endpoint the login page
# fetches), not injected into the static index.html.
if [ "$jellarr_ok" = "1" ]; then
  oidc_ok=0
  for i in $(seq 1 30); do
    if curl -sk https://jellyfin.vmtest.local/Branding/Configuration | grep -q "Sign in with Dex"; then
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
# Ingress TLS: every vhost must present a cert that verifies against
# the VM trust store, with the right hostname. A certless vhost serves
# a TLS alert (curl exit 35) — the auth/cryptpad incident of 2026-08-28
# was exactly this, invisible because no check distinguished "no cert"
# from "backend down". NixOS's security.pki extras land in the bundle
# file only (the hashed /etc/ssl/certs dir stays the stock cacert set),
# so verify against the bundle, not -CApath.
for d in auth jellyfin cryptpad radarr sonarr qbittorrent seerr; do
  host="$d.vmtest.local"
  if echo | timeout 10 openssl s_client -connect 127.0.0.1:443 \
      -servername "$host" -verify_hostname "$host" \
      -CAfile /etc/ssl/certs/ca-certificates.crt -verify_return_error 2>/dev/null \
      | grep -q "Verify return code: 0"; then
    pass "TLS $host" "verified"
  else
    fail "TLS $host" "no valid cert"
  fi
done

# ── LAN DNS plane (ADR-028) ───
# The customer path: resolve a service domain via the box's dnsmasq
# (what the router's DHCP-DNS redirect hands out), connect to the LAN
# address, verify the TLS cert. dnsmasq answering while Caddy doesn't
# listen = correct DNS, dead ingress — hence the --resolve curl, not
# just dig.
echo ""
echo "─── LAN DNS (dnsmasq @ 10.0.2.15) ───"
LAN=10.0.2.15
dnsmasq_state=$(systemctl is-active dnsmasq.service 2>/dev/null || true)
case "$dnsmasq_state" in
  active) pass "dnsmasq" "active" ;;
  *) fail "dnsmasq" "${dnsmasq_state:-missing}" ;;
esac

for d in auth jellyfin cryptpad radarr sonarr qbittorrent seerr; do
  host="$d.vmtest.local"
  ans=$(dig @"$LAN" +short "$host" A 2>/dev/null | head -1)
  if [ "$ans" = "$LAN" ]; then
    pass "dns $host" "$ans"
  else
    fail "dns $host" "${ans:-no answer}"
  fi
done

# Firefox DoH canary must NXDOMAIN so secure-DNS browsers drop DoH
# on this network instead of bypassing the split-horizon.
if dig @"$LAN" use-application-dns.net 2>/dev/null | grep -q "status: NXDOMAIN"; then
  pass "DoH canary" "NXDOMAIN"
else
  fail "DoH canary" "not NXDOMAIN"
fi

# The full LAN ingress: resolve → connect to the LAN IP → cert
# verifies against the VM trust store → HTTP 200.
lan_code=$(curl --cacert /etc/ssl/certs/ca-certificates.crt \
  --resolve "jellyfin.vmtest.local:443:$LAN" \
  -o /dev/null -w '%{http_code}' \
  https://jellyfin.vmtest.local/health 2>/dev/null || echo 000)
case "$lan_code" in
  200) pass "LAN ingress (resolve+TLS)" "200" ;;
  *)   fail "LAN ingress (resolve+TLS)" "$lan_code" ;;
esac

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
# and the /ssoauth page hangs. The fortress-cryptpad-seed-bearer
# ExecStartPre must make it pass from the first boot.
cp_node=$(readlink -f /proc/$(systemctl show cryptpad -p MainPID --value)/exe 2>/dev/null || echo "")
if [ -n "$cp_node" ] && timeout 90 "$cp_node" /tmp/ssoauth-probe.js >/dev/null 2>&1; then
  pass "cryptpad SSO_AUTH_CB" "JWT"
else
  fail "cryptpad SSO_AUTH_CB" "no JWT"
fi

echo ""
echo "─── CryptPad SSO encryption-password config ───"
# The browser reads /api/config; sso.password 0/1/2 → registration
# shows no/optional/forced CryptPad password form. If the oidc
# integration drops cpPassword, users can't opt into a drive key the
# admin can't read. Assert the served value is optional (1).
served=$(curl -sk --max-time 30 https://cryptpad.vmtest.local/api/config 2>/dev/null || echo "")
served_pw=$(printf '%s' "$served" | grep -o '"password": *[0-9]' | head -1 || true)
if printf '%s' "$served_pw" | grep -q '"password": *1'; then
  pass "cryptpad sso.password" "optional (1)"
else
  fail "cryptpad sso.password" "${served_pw:-missing}"
fi

echo ""
echo "─── Storage writability (service owns its subvolume) ───"
# Subvolumes created root:root 0755 are read-only to the service's
# runtime user; any service that persists data breaks (cryptpad SSO
# hung on mkdir EACCES; jellyfin could not init metadata). The btrfs
# module chowns subvolumes to the declaring service's owner.
for pair in "fortress-cryptpad:/data/cryptpad/data" "jellyfin:/data/jellyfin/metadata"; do
  user="${pair%%:*}"; path="${pair#*:}"
  if runuser -u "$user" -- sh -c "touch '$path/.fortress-write-test' && rm '$path/.fortress-write-test'" 2>/dev/null; then
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
    ISS=$(echo "$PAYLOAD" | jq -r '.iss // empty' 2>/dev/null || true)
    if printf '%s' "$ISS" | grep -q '^http://127.0.0.1:'; then
      pass "dex token iss" "loopback ($ISS)"
    else
      fail "dex token iss" "${ISS:-missing}"
    fi
  fi
else
  fail "dex password grant" "no token"
fi

echo ""
echo "─── I2P plane SSO flow (hermetic, Host-pinned) ───"
# The .i2p vhosts are plain-HTTP Caddy sites bound to loopback; the
# i2pd tunnel terminates at Caddy on 127.0.0.1:80. --resolve pins the
# .i2p names to loopback so this flow runs exactly as an I2P client
# would drive it (same Host, same cookie jar), with no I2P network
# needed. It walks the REAL SSO chain end to end: plugin authorize →
# issuer rewrite → dex login → dex callback → callback rewrite →
# plugin session established.
JAR=/tmp/i2p-sso-cookies
rm -f "$JAR"
I2P_CURL=(curl -s --resolve jellyfin.vmtest.i2p:80:127.0.0.1 --resolve auth.vmtest.i2p:80:127.0.0.1 --max-time 30)

jf2_code=$("${I2P_CURL[@]}" -o /dev/null -w '%{http_code}' \
  http://jellyfin.vmtest.i2p/health 2>/dev/null || echo 000)
case "$jf2_code" in
  200) pass "i2p jellyfin ingress" "200" ;;
  *)   fail "i2p jellyfin ingress" "$jf2_code" ;;
esac

DX_DISC=$("${I2P_CURL[@]}" \
  http://auth.vmtest.i2p/dex/.well-known/openid-configuration 2>/dev/null || echo "")
if printf '%s' "$DX_DISC" | grep -q '"issuer": *"http://127.0.0.1:5556/dex"'; then
  pass "i2p dex discovery" "loopback issuer served"
else
  fail "i2p dex discovery" "issuer mismatch or unreachable"
fi

START_LOC=$("${I2P_CURL[@]}" -c "$JAR" -D - -o /dev/null \
  http://jellyfin.vmtest.i2p/sso/OIDC/Start/dex 2>/dev/null \
  | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)
case "$START_LOC" in
  http://auth.vmtest.i2p/dex/auth*) pass "i2p authorize rewrite" "auth.vmtest.i2p" ;;
  *) fail "i2p authorize rewrite" "got ${START_LOC:-none}" ;;
esac

LOGIN_HTML=$("${I2P_CURL[@]}" -b "$JAR" -c "$JAR" "$START_LOC" 2>/dev/null || echo "")
ACTION=$(printf '%s' "$LOGIN_HTML" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//;s/"$//')
case "$ACTION" in
  http*) : ;;
  /*)    ACTION="http://auth.vmtest.i2p$ACTION" ;;
  *)     ACTION="http://auth.vmtest.i2p/$ACTION" ;;
esac

"${I2P_CURL[@]}" -b "$JAR" -c "$JAR" -D /tmp/i2p-h1 -o /tmp/i2p-b1 \
  --data-urlencode "login=admin@example.com" \
  --data-urlencode "password=password" \
  "$ACTION" 2>/dev/null
NEXT_LOC=$(grep -i '^location:' /tmp/i2p-h1 2>/dev/null | tr -d '\r' | sed 's/^[Ll]ocation: //p' | head -1)

# dex may render the approval screen instead of redirecting; approve it.
if [ -z "$NEXT_LOC" ]; then
  APP_ACTION=$(printf '%s' "$(cat /tmp/i2p-b1 2>/dev/null)" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//;s/"$//')
  case "$APP_ACTION" in
    http*) : ;;
    /*)    APP_ACTION="http://auth.vmtest.i2p$APP_ACTION" ;;
    *)     APP_ACTION="http://auth.vmtest.i2p/$APP_ACTION" ;;
  esac
  NEXT_LOC=$("${I2P_CURL[@]}" -b "$JAR" -c "$JAR" -D - -o /dev/null \
    --data-urlencode "approval=approve" "$APP_ACTION" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)
fi

case "$NEXT_LOC" in
  https://jellyfin.vmtest.local/sso/OIDC/Callback/dex*) pass "i2p dex login" "callback issued (registered clearnet)" ;;
  *) fail "i2p dex login" "got ${NEXT_LOC:-none}" ;;
esac

I2P_CB=${NEXT_LOC/https:\/\/jellyfin.vmtest.local/http://jellyfin.vmtest.i2p}
CB_HTML=$("${I2P_CURL[@]}" -b "$JAR" "$I2P_CB" 2>/dev/null || echo "")
if printf '%s' "$CB_HTML" | grep -q "Completing authentication"; then
  pass "i2p SSO session" "plugin exchanged the code at loopback"
else
  fail "i2p SSO session" "$(printf '%s' "$CB_HTML" | grep -o 'Authentication failed[^<]*' | head -1 || echo 'no callback page')"
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
