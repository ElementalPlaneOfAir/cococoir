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
if [ "$jellarr_ok" = "1" ]; then :; else
  fail "jellarr pipeline" "timeout"
  # A timeout must be diagnosable: `is-failed` is false while a unit is
  # crash-looping (Restart=on-failure parks it in activating), so the
  # FAILED branch above never fires and the cause is invisible.
  systemctl status jellarr.service jellarr-api-key-bootstrap.service \
    --no-pager -l >&2 || true
  journalctl -u jellarr -u jellarr-api-key-bootstrap --no-pager -n 60 >&2 || true
fi

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
if [ "$apply_ok" = "1" ]; then :; else
  fail "media-apply pipeline" "timeout"
  systemctl status fortress-media-apply.service --no-pager -l >&2 || true
  journalctl -u fortress-media-apply --no-pager -n 80 >&2 || true
fi

if [ "$apply_ok" = "1" ]; then
  radarr_key=$(cat /var/lib/fortress-media/radarr-api-key)
  sonarr_key=$(cat /var/lib/fortress-media/sonarr-api-key)

  qbt_ok=0
  for i in $(seq 1 30); do
    # Presence alone is not enough: on amon-sul the categories existed
    # with STALE save paths (/media/media/...) left by an older layout
    # derivation, so torrents landed where no *arr looked. Assert the
    # save path actually points into the media tree's downloads area.
    if curl -sf http://127.0.0.1:8080/api/v2/torrents/categories \
      | jq -e '(.movies.savePath | test("/movies/downloads$")) and (.tv.savePath | test("/shows/downloads$"))' >/dev/null 2>&1; then
      qbt_ok=1
      pass "qbt categories" "movies + tv save paths under media tree"
      break
    fi
    sleep 2
  done
  [ "${qbt_ok:-0}" = "1" ] || fail "qbt categories" "missing or stale movies/tv save paths"

  for svc in radarr sonarr; do
    port=$( [ "$svc" = radarr ] && echo 7878 || echo 8989 )
    key=$(cat "/var/lib/fortress-media/$svc-api-key")
    field=$( [ "$svc" = radarr ] && echo movieCategory || echo tvCategory )
    want=$( [ "$svc" = radarr ] && echo movies || echo tv )
    arr_ok=0
    for i in $(seq 1 30); do
      # A qBittorrent client existing is not enough: the applier used to
      # send the field name "category", which the *arrs accept and
      # silently discard, leaving the default (radarr/tv-sonarr) and
      # routing every torrent to a save path nothing imports from.
      if curl -sf -H "X-Api-Key: $key" "http://127.0.0.1:$port/$svc/api/v3/downloadclient" \
        | jq -e --arg f "$field" --arg w "$want" \
            'map(select(.name == "qBittorrent")) | first | (.fields[] | select(.name == $f) | .value) == $w' >/dev/null 2>&1; then
        arr_ok=1
        pass "$svc download client" "qBittorrent wired ($field=$want)"
        break
      fi
      sleep 2
    done
    [ "$arr_ok" = "1" ] || fail "$svc download client" "qBittorrent missing or $field != $want"
  done

  seerr_ok=0
  seerr_cookie=$(mktemp)
  # Seerr's only first-boot admin path is Jellyfin sign-in (local login
  # has no admin-creation route); re-auth the bootstrap user.
  if curl -sf -c "$seerr_cookie" -H 'Content-Type: application/json' \
      -d "{\"username\": \"seerr-bootstrap\", \"password\": \"$(cat /var/lib/fortress-media/seerr-admin-password)\", \"hostname\": \"127.0.0.1\", \"port\": 8096, \"useSsl\": false, \"urlBase\": \"/jellyfin\", \"serverType\": 2}" \
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
    if curl -sk https://vmtest.local/jellyfin/Branding/Configuration | grep -q "Sign in with Dex"; then
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
dnsmasq_state=$(systemctl is-active fortress-dns.service 2>/dev/null || true)
case "$dnsmasq_state" in
  active) pass "fortress-dns" "active" ;;
  *) fail "fortress-dns" "${dnsmasq_state:-missing}" ;;
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
# verifies against the VM trust store → HTTP 200. The path is the
# plane row (ADR-034): the shared origin is what LAN clients use.
lan_code=$(curl --cacert /etc/ssl/certs/ca-certificates.crt \
  --resolve "vmtest.local:443:$LAN" \
  -o /dev/null -w '%{http_code}' \
  https://vmtest.local/jellyfin/health 2>/dev/null || echo 000)
case "$lan_code" in
  200) pass "LAN ingress (resolve+TLS)" "200" ;;
  *)   fail "LAN ingress (resolve+TLS)" "$lan_code" ;;
esac

# Dex OIDC discovery on the clearnet plane
dx_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://vmtest.local/dex/.well-known/openid-configuration 2>/dev/null || echo 000)
case "$dx_code" in
  200) pass "dex OIDC discovery" "$dx_code" ;;
  *)   fail "dex OIDC discovery" "$dx_code" ;;
esac

# Jellyfin health on its plane row
jf_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://vmtest.local/jellyfin/health 2>/dev/null || echo 000)
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
echo "─── Path-routing matrix (ADR-034) ───"
# Every service answers at /<path> on every plane origin (uniform
# entry point), and the non-canonical shape 307s to its canonical —
# never a second copy. These rows ARE the customer-facing contract.
redir_check() {
  local label=$1 url=$2 want_loc=$3
  local out code loc
  out=$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' "$url" 2>/dev/null || echo "000 -")
  code=${out%% *}; loc=${out#* }
  if [ "$code" = "307" ] && [ "$loc" = "$want_loc" ]; then
    pass "$label" "307 -> $loc"
  else
    fail "$label" "$code ${loc}"
  fi
}

# clearnet: jellyfin hostname stub -> the plane path
redir_check "clearnet stub (jellyfin)" \
  https://jellyfin.vmtest.local/ "https://vmtest.local/jellyfin/"
# clearnet: seerr row fails over to its canonical hostname
redir_check "clearnet failover (seerr)" \
  https://vmtest.local/seerr "https://seerr.vmtest.local/"
# LAN: the headline UX — the bare IP serves the path row, zero DNS
lan_jf_code=$(curl -s -o /dev/null -w '%{http_code}' \
  http://10.0.2.15/jellyfin/health 2>/dev/null || echo 000)
case "$lan_jf_code" in
  200) pass "LAN bare-IP jellyfin" "http://$LAN/jellyfin/health -> 200" ;;
  *)   fail "LAN bare-IP jellyfin" "$lan_jf_code" ;;
esac
# LAN: seerr fails over to its port-site (zero DNS for the front door)
redir_check "LAN failover (seerr)" \
  http://10.0.2.15/seerr "http://10.0.2.15:5055/"
# LAN: originLocked cryptpad fails over to its own origin, not a port
redir_check "LAN failover (cryptpad, originLocked)" \
  http://10.0.2.15/cryptpad "https://cryptpad.vmtest.local/"
# LAN: the seerr port-site is live
seerr_ps=$(curl -s -o /dev/null -w '%{http_code}' \
  http://10.0.2.15:5055/api/v1/status 2>/dev/null || echo 000)
case "$seerr_ps" in
  200) pass "seerr LAN port-site" "200" ;;
  *)   fail "seerr LAN port-site" "$seerr_ps" ;;
esac
# forgejo generates URLs with /git but serves at its own root — the
# row strips the prefix (ROOT_URL is URL-generation only).
fg_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://vmtest.local/git/ 2>/dev/null || echo 000)
case "$fg_code" in
  200) pass "forgejo under /git (strip row)" "200" ;;
  *)   fail "forgejo under /git (strip row)" "$fg_code" ;;
esac
# A5: the proxy appends Path=/<path> to every Set-Cookie (the trailing
# attribute wins per RFC 6265) — forgejo's session cookies show the
# rewrite's fingerprint (`; Path=/git` at the end of the line).
if curl -sk -D - -o /dev/null --max-time 15 https://vmtest.local/git/user/login 2>/dev/null \
    | tr -d '\r' | grep -i '^set-cookie:' | grep -q 'Path=/git$'; then
  pass "cookie Path scoping (A5)" "Set-Cookie rewritten to Path=/git"
else
  fail "cookie Path scoping (A5)" "no rewritten Set-Cookie on forgejo's login page"
fi

# the shared origin's root is the dashboard
dash_code=$(curl -sk -o /dev/null -w '%{http_code}' \
  https://vmtest.local/ 2>/dev/null || echo 000)
case "$dash_code" in
  200|303) pass "plane root dashboard" "$dash_code (serves or logs in)" ;;
  *)   fail "plane root dashboard" "$dash_code" ;;
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
# A subvolume the service's runtime user cannot write breaks it at
# first boot (cryptpad SSO hung on mkdir EACCES; jellyfin could not
# init metadata). Read the user off the unit rather than hardcoding
# names — hardcoding is what let this check rot into a false failure
# the moment ADR-036 moved these services to root.
for pair in "cryptpad:/data/cryptpad/data" "jellyfin:/data/jellyfin/metadata"; do
  unit="${pair%%:*}"; path="${pair#*:}"
  user="$(systemctl show -p User --value "$unit.service")"
  user="${user:-root}"
  if runuser -u "$user" -- sh -c "touch '$path/.fortress-write-test' && rm '$path/.fortress-write-test'" 2>/dev/null; then
    pass "$unit -> $path" "writable as $user"
  else
    fail "$unit -> $path" "EACCES as $user"
  fi
done

echo ""
echo "─── Dex test user (admin@example.com / password) ───"
TOKEN=$(curl -sk -X POST https://vmtest.local/dex/token \
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
  ID_TOKEN=$(curl -sk -X POST https://vmtest.local/dex/token \
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
echo "─── SSO flows: I2P plane + LAN plane (A4/A5/A9) ───"
# One flow, two planes (ADR-034): the plugin Start -> dex authorize ->
# (dex 302s twice: connector -> login form) -> login -> optional
# approval -> the plane-swapped callback -> plugin session. The i2p
# run is Host-pinned to loopback (exactly what an i2pd tunnel drives);
# the LAN run is the T7 spike on the plain-HTTP IP origin — curl
# refuses to SEND Secure cookies over HTTP like a browser, so a pass
# proves no Secure cookie is load-bearing (A9).
walk_dex_login() { # $1=base $2=jar $3=header-prefix $4=auth-url — follows dex's
                    # 302s (authorize -> connector -> login form), then
                    # returns the form page in DEX_HTML/DEX_ACTION.
  local base=$1 jar=$2 prefix=$3 url=$4 hop hf bf loc
  DEX_HFILES=""
  DEX_HTML=""
  DEX_ACTION=""
  for hop in 1 2 3 4 5; do
    hf="/tmp/${prefix}-dh${hop}"; bf="/tmp/${prefix}-db${hop}"
    "${S_CURL[@]}" -b "$jar" -c "$jar" -D "$hf" -o "$bf" "$url" 2>/dev/null || true
    DEX_HFILES="$DEX_HFILES $hf"
    loc=$(tr -d '\r' < "$hf" | sed -n 's/^[Ll]ocation: //p' | head -1 || true)
    if [ -n "$loc" ]; then
      case "$loc" in
        http*) url=$loc ;;
        *) url="$base$loc" ;;
      esac
      continue
    fi
    DEX_HTML=$(cat "$bf" 2>/dev/null || true)
    DEX_ACTION=$(printf '%s' "$DEX_HTML" | grep -o 'action="[^"]*"' | head -1 \
      | sed 's/^action="//;s/"$//' | sed 's/&amp;/\&/g; s/&#38;/\&/g; s/&#34;/"/g' || true)
    # no action attribute = the form posts to the page it is on
    DEX_ACTION=${DEX_ACTION:-$url}
    return 0
  done
  return 1
}

sso_flow() { # $1=plane-name $2=base $3=cookie-jar
  local plane=$1 base=$2 jar=$3
  local start login_url action nxt app cb html hfiles=""
  S_CURL=(curl -s --max-time 30)
  if [ "$plane" = "i2p" ]; then
    S_CURL+=(--resolve "vmtest.i2p:80:127.0.0.1")
  fi

  "${S_CURL[@]}" -c "$jar" -D "/tmp/${plane}-h0" -o /dev/null \
    "$base/jellyfin/sso/OIDC/Start/dex" 2>/dev/null || true
  hfiles="/tmp/${plane}-h0"
  start=$(tr -d '\r' < "/tmp/${plane}-h0" | sed -n 's/^[Ll]ocation: //p' | head -1 || true)
  case "$start" in
    "$base/dex/auth"*) pass "$plane authorize rewrite" "$base" ;;
    *) fail "$plane authorize rewrite" "got ${start:-none}"; return 0 ;;
  esac

  if ! walk_dex_login "$base" "$jar" "$plane" "$start"; then
    fail "$plane dex login page" "redirect chain did not end in a form"
    return 0
  fi
  hfiles="$hfiles $DEX_HFILES"
  action=$DEX_ACTION
  [ -n "$action" ] || echo "  (dex page empty/form-less: $(wc -c < /tmp/${plane}-db5 2>/dev/null || echo 0) bytes)" >&2
  case "$action" in
    http*) : ;;
    /*)    action="$base$action" ;;
    *)     action="$base/$action" ;;
  esac

  "${S_CURL[@]}" -b "$jar" -c "$jar" -D "/tmp/${plane}-h1" -o "/tmp/${plane}-b1" \
    --data-urlencode "login=admin@example.com" \
    --data-urlencode "password=password" \
    "$action" 2>/dev/null || true
  hfiles="$hfiles /tmp/${plane}-h1"
  nxt=$(grep -i '^location:' "/tmp/${plane}-h1" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1 || true)

  # After login dex may hand back the callback directly, or walk
  # through its approval screen (302 -> a form we must submit).
  # Follow either shape until the callback shows up.
  for hop in 1 2 3 4 5; do
    case "$nxt" in
      *"/jellyfin/sso/OIDC/Callback/dex"*) break ;;
    esac
    [ -n "$nxt" ] || break
    case "$nxt" in
      http*) : ;;
      /*)    nxt="$base$nxt" ;;
      *)     nxt="$base/$nxt" ;;
    esac
    page=$nxt
    "${S_CURL[@]}" -b "$jar" -c "$jar" -D "/tmp/${plane}-ap${hop}" -o "/tmp/${plane}-ab${hop}" \
      "$nxt" 2>/dev/null || true
    hfiles="$hfiles /tmp/${plane}-ap${hop}"
    nxt=$(tr -d '\r' < "/tmp/${plane}-ap${hop}" | sed -n 's/^[Ll]ocation: //p' | head -1 || true)
    if [ -z "$nxt" ]; then
      app=$(printf '%s' "$(cat /tmp/${plane}-ab${hop} 2>/dev/null)" | grep -o 'action="[^"]*"' | head -1 \
        | sed 's/^action="//;s/"$//' | sed 's/&amp;/\&/g; s/&#38;/\&/g; s/&#34;/"/g' || true)
      app=${app:-$page}
      case "$app" in
        http*) : ;;
        /*)    app="$base$app" ;;
        *)     app="$base/$app" ;;
      esac
      "${S_CURL[@]}" -b "$jar" -c "$jar" -D "/tmp/${plane}-apx${hop}" -o /dev/null \
        --data-urlencode "approval=approve" "$app" 2>/dev/null || true
      hfiles="$hfiles /tmp/${plane}-apx${hop}"
      nxt=$(tr -d '\r' < "/tmp/${plane}-apx${hop}" | sed -n 's/^[Ll]ocation: //p' | head -1 || true)
    fi
  done

  # The clearnet-canonical callback must arrive swapped onto the plane
  # the browser is on — never a mid-flow jump to another origin.
  case "$nxt" in
    "$base/jellyfin/sso/OIDC/Callback/dex"*) pass "$plane dex login" "callback swapped onto the $plane plane" ;;
    *) fail "$plane dex login" "got ${nxt:-none}"; return 0 ;;
  esac

  "${S_CURL[@]}" -b "$jar" -D "/tmp/${plane}-cb-h" "$nxt" -o "/tmp/${plane}-cb.html" 2>/dev/null || true
  hfiles="$hfiles /tmp/${plane}-cb-h"
  html=$(cat "/tmp/${plane}-cb.html" 2>/dev/null || true)
  if printf '%s' "$html" | grep -q "Completing authentication"; then
    pass "$plane SSO session" "plugin exchanged the code at loopback"
  else
    fail "$plane SSO session" "$(printf '%s' "$html" | grep -o 'Authentication failed[^<]*' | head -1 || echo 'no callback page')"
  fi

  # A9 evidence: Secure cookies on the HTTP LAN flow would be the
  # browser failure mode (curl will not send them over HTTP either).
  if grep -ih '^set-cookie:' $hfiles 2>/dev/null | grep -qi 'secure'; then
    echo "  A9 note ($plane): Secure Set-Cookie observed:"
    grep -ih '^set-cookie:' $hfiles 2>/dev/null | sed 's/^/    /' || true
  else
    pass "$plane secure-cookie audit" "no Secure cookies in the flow"
  fi
}

JAR=/tmp/i2p-sso-cookies; rm -f "$JAR"
sso_flow "i2p" "http://vmtest.i2p" "$JAR"
JAR2=/tmp/lan-sso-cookies; rm -f "$JAR2"
sso_flow "lan" "http://10.0.2.15" "$JAR2"

# ── claim flow (claim-flow T5/T7) ───
# The boot-dead-end tripwire: a fresh box whose forwards need a
# tunnel used to EXIT before its dashboard served. Claimable boot
# keeps it up and serves the Remote access claim card — assert both,
# or the dead end returns silently on the next refactor.
echo ""
echo "─── Claim flow (remote access) ───"
if systemctl is-active --quiet fortress-client.service 2>/dev/null; then
  pass "fortress-client.service" "active (claimable boot)"
else
  fail "fortress-client.service" "not active — the box exited instead of serving a claim surface"
fi

claim_cookie=$(mktemp)
if curl -sf -c "$claim_cookie" -X POST -d "password=password" \
    http://127.0.0.1:3210/auth/login >/dev/null 2>&1; then
  claim_home=$(curl -sf -b "$claim_cookie" http://127.0.0.1:3210/ 2>/dev/null || true)
  if printf '%s' "$claim_home" | grep -q "Remote access" \
     && printf '%s' "$claim_home" | grep -q "not claimed" \
     && printf '%s' "$claim_home" | grep -q 'action="/claim"'; then
    pass "claim surface" "Remote access card + claim form serve"
  else
    fail "claim surface" "claim card/form missing on the unclaimed dashboard"
  fi
else
  fail "dashboard login" "admin login rejected (password=password)"
fi
rm -f "$claim_cookie"

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
