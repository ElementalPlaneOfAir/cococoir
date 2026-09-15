#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# container-e2e.sh — the container tier's "prove it works" button.
# Builds the fortress-container rootfs tarball, imports it into the
# host's OCI runtime (docker or rootless podman), boots the full
# NixOS system inside the container, and asserts the stack comes
# up: no failed units, every service active, Jellyfin health +
# "Sign in with Dex" branding, Dex OIDC discovery, CryptPad
# checkup, non-public vhost 403, and /data persistence across a
# container recreate.
#
# Run this before claiming any container-tier change "works".
# Requires: a Linux host with docker or podman, and Nix.
set -euo pipefail

cd "$(dirname "$0")/.."

CONTAINER=fortress-demo
PORT=8443

# Prefer docker (the collaborator tier's documented runtime); fall
# back to podman (same OCI API).
if command -v docker >/dev/null 2>&1; then RT=docker; elif command -v podman >/dev/null 2>&1; then RT=podman; else
  echo "container-e2e: needs docker or podman on PATH" >&2; exit 1; fi
echo "==> Runtime: $RT"

echo "==> Killing stale demo container (would poison this run's assertions)"
$RT rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "==> Building rootfs tarball"
tarball="$(nix build --print-out-paths \
  .#nixosConfigurations.fortress-container.config.system.build.tarball \
  --no-link | tail -1)"

echo "==> Importing (streamed: a direct <file.tar.xz> import wedged"
echo "    at 100% CPU under rootless podman; the pipe does not)"
xz -dc "$tarball/tarball/nixos-system-x86_64-linux.tar.xz" | $RT import - fortress:demo >/dev/null

echo "==> Booting container (systemd as PID 1, privileged)"
$RT run --privileged -d --name "$CONTAINER" -p ${PORT}:443 \
  -v fortress-data:/data fortress:demo /init >/dev/null
cleanup() { $RT rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

exec_in() { $RT exec "$CONTAINER" /run/current-system/sw/bin/systemctl "$@" 2>/dev/null; }

echo "==> Waiting for the boot to settle"
sleep 60

echo "==> Asserting: no failed units"
if [ -n "$(exec_in --failed --no-legend)" ]; then
  echo "container-e2e: FAILED units inside the container:" >&2
  exec_in --failed --no-legend >&2
  exit 1
fi

echo "==> Asserting: core services active"
for s in caddy cryptpad jellyfin dex seerr; do
  state="$(exec_in is-active "$s")"
  if [ "$state" != "active" ]; then
    echo "container-e2e: service $s is '$state', expected active" >&2
    exit 1
  fi
done

curl_assert() { # name expected-status curl-args...
  local name=$1 expect=$2 got
  shift 2
  got="$(curl -k --max-time 15 -s -o /dev/null -w '%{http_code}' "$@")"
  if [ "$got" != "$expect" ]; then
    echo "container-e2e: $name returned HTTP $got, expected $expect" >&2
    exit 1
  fi
  echo "    $name: $got"
}

echo "==> Asserting: HTTP plane through the published port"
curl_assert "jellyfin /health" 200 \
  --resolve jellyfin.vmtest.local:${PORT}:127.0.0.1 \
  https://jellyfin.vmtest.local:${PORT}/health
curl_assert "dex OIDC discovery" 200 \
  --resolve auth.vmtest.local:${PORT}:127.0.0.1 \
  https://auth.vmtest.local:${PORT}/dex/.well-known/openid-configuration
curl_assert "cryptpad /checkup/" 200 \
  --resolve cryptpad.vmtest.local:${PORT}:127.0.0.1 \
  https://cryptpad.vmtest.local:${PORT}/checkup/
# The factory contract: a non-public vhost answers 403, not the app.
curl_assert "radarr (non-public) 403" 403 \
  --resolve radarr.vmtest.local:${PORT}:127.0.0.1 \
  https://radarr.vmtest.local:${PORT}/

echo "==> Asserting: OIDC branding (jellarr applied inside the container)"
branding=""
for i in $(seq 1 18); do
  branding="$(curl -k --max-time 15 -s --resolve jellyfin.vmtest.local:${PORT}:127.0.0.1 \
    https://jellyfin.vmtest.local:${PORT}/Branding/Configuration \
    | jq -r '.LoginDisclaimer // empty')"
  if printf '%s' "$branding" | grep -q 'Sign in with Dex'; then break; fi
  sleep 10
done
if ! printf '%s' "$branding" | grep -q 'Sign in with Dex'; then
  echo "container-e2e: 'Sign in with Dex' branding missing from Jellyfin branding — the OIDC integration did not apply inside the container" >&2
  exit 1
fi
echo "    branding: 'Sign in with Dex' present"

echo "==> Asserting: /data persistence across a container recreate"
exec_bash() { $RT exec "$CONTAINER" /run/current-system/sw/bin/bash -c \
  "export PATH=/run/current-system/sw/bin:\$PATH; $1"; }
exec_bash 'echo container-e2e-marker > /data/media/movies/marker.txt'
$RT rm -f "$CONTAINER" >/dev/null
$RT run --privileged -d --name "$CONTAINER" -p ${PORT}:443 \
  -v fortress-data:/data fortress:demo /init >/dev/null
sleep 60
found="$(exec_bash 'cat /data/media/movies/marker.txt 2>/dev/null' || true)"
if [ "$found" != "container-e2e-marker" ]; then
  echo "container-e2e: the /data volume did not survive a container recreate" >&2
  exit 1
fi
echo "    /data persisted across recreate"

curl_assert "jellyfin /health (after recreate)" 200 \
  --resolve jellyfin.vmtest.local:${PORT}:127.0.0.1 \
  https://jellyfin.vmtest.local:${PORT}/health

stamp="Last container e2e: PASS — $(date +%F) — $(git rev-parse --short HEAD)"
sed -i "s|^Last container e2e:.*|${stamp}|" docs/STATUS.md
grep -q '^Last container e2e:' docs/STATUS.md || \
  sed -i "s|^\(Last e2e:.*\)|\1\n${stamp}|" docs/STATUS.md

echo "==> Container E2E PASS (${stamp})"
