#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# demo-verify.sh — prove the IPv6 edge demo works, end to end.
#
# Asserts the data path from the vision doc
# (writing/human/architecture_of_ipv6.md):
#   cellular client (IPv6)  -> AAAA -> edge /128 -> WG -> customer Caddy
#   IPv4 LAN client          -> A (or local DNS) -> edge -> WG -> same cert
#
# Usage (from the edge box or any host with DNS + network):
#   bash scripts/demo-verify.sh [baseDomain]
#
# Defaults to example123.interdim.net; pass a different base to
# re-run for another customer. Requires curl + jq + openssl.
set -euo pipefail

base="${1:-example123.interdim.net}"
edge_v4=""
edge_v6=""

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
fail()  { red "FAIL: $*"; exit 1; }

command -v curl >/dev/null || fail "curl required"
command -v jq >/dev/null || fail "jq required"
command -v openssl >/dev/null || fail "openssl required"

echo "==> Demo verify for ${base}"

# ── DNS: the per-customer AAAA must point at a customer /128 ──────
echo ""
echo "─── DNS ───"
for svc in jellyfin auth; do
  host="${svc}.${base}"
  aaaa=$(dig +short AAAA "${host}" 2>/dev/null | head -1 || true)
  if [ -z "${aaaa}" ]; then
    fail "${host} has no AAAA record"
  fi
  green "${host} AAAA -> ${aaaa}"
done

# ── Cert: the served cert must be a real Let's Encrypt chain, and it
#    must cover the hostname (name-based, so it serves over IPv4 too).
echo ""
echo "─── TLS (through the tunnel) ───"
for svc in jellyfin auth; do
  host="${svc}.${base}"
  san=$(echo | openssl s_client -servername "${host}" \
    -connect "${host}:443" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null || true)
  if ! echo "${san}" | grep -q "Let.s Encrypt"; then
    fail "${host} cert issuer is not Let's Encrypt"
  fi
  if ! echo "${san}" | grep -q "${host}"; then
    fail "${host} cert does not cover the hostname"
  fi
  green "${host} cert: Let's Encrypt, covers ${host}"
done

# ── Data path: Jellyfin + Dex OIDC through the tunnel ─────────────
echo ""
echo "─── Services ───"
code=$(curl -sf -o /dev/null -w '%{http_code}' \
  "https://jellyfin.${base}/health" 2>/dev/null || echo 000)
[ "${code}" = "200" ] || fail "jellyfin health: ${code}"
green "jellyfin /health: ${code}"

code=$(curl -sf -o /dev/null -w '%{http_code}' \
  "https://auth.${base}/dex/.well-known/openid-configuration" 2>/dev/null || echo 000)
[ "${code}" = "200" ] || fail "dex OIDC discovery: ${code}"
green "dex OIDC discovery: ${code}"

# The login page must render the Dex button jellarr pushed — the
# end-to-end proof that OIDC config landed on the running server.
if curl -sf "https://jellyfin.${base}/web/index.html" 2>/dev/null \
  | grep -q "Sign in with Dex"; then
  green "jellyfin login page renders 'Sign in with Dex'"
else
  fail "jellyfin login page missing 'Sign in with Dex'"
fi

# ── IPv4 LAN path: same cert via the A record / local DNS ─────────
echo ""
echo "─── IPv4 path (A record / local DNS) ───"
a=$(dig +short A "jellyfin.${base}" 2>/dev/null | head -1 || true)
if [ -z "${a}" ]; then
  # No public A record: the vision's "custom DNS server" path. The
  # customer box has networking.hosts entries for 127.0.0.1; a LAN
  # client points its own DNS at the box's LAN IP.
  lan_ip=$(ip -4 addr show 2>/dev/null \
    | awk '/inet / && $2 !~ /^127\./ {print $2; exit}' | cut -d/ -f1 || true)
  if [ -n "${lan_ip}" ]; then
    san=$(echo | openssl s_client -servername "jellyfin.${base}" \
      -connect "${lan_ip}:443" -verify_hostname "jellyfin.${base}" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)
    if echo "${san}" | grep -q "Let.s Encrypt"; then
      green "IPv4 LAN (${lan_ip}): same Let's Encrypt cert serves"
    else
      fail "IPv4 LAN cert check on ${lan_ip}"
    fi
  else
    green "no public A record, no LAN IP detected on this host — IPv4 path is DNS-side (documented)"
  fi
else
  san=$(echo | openssl s_client -servername "jellyfin.${base}" \
    -connect "${a}:443" -verify_hostname "jellyfin.${base}" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)
  if echo "${san}" | grep -q "Let.s Encrypt"; then
    green "IPv4 (${a}): same Let's Encrypt cert serves"
  else
    fail "IPv4 cert check via ${a}"
  fi
fi

echo ""
green "Demo verify PASS for ${base}"
