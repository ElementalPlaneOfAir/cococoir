#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: ensure the local node is in the
# cluster view, apply single-node layout, import the global S3 key,
# create buckets, and allow the global key on each.
#
# Ported from v1/clan-services/garage/bucket-init.sh. The change
# from v1: $CLAN_VAR_S3_KEY_DIR (the clan-core var dir) is renamed
# to $COCOCOIR_S3_KEY_DIR (the sops-nix file dir), and the script
# no longer takes a `--zone <instance-name>` from clan. Otherwise
# the runtime logic is unchanged.
#
# Usage: bucket-init.sh \
#   --global-dir <path> --address <rpc-addr> --zone <zone> \
#   --capacity <cap> --bucket <name> [--bucket <name>...]
#
# Required env:
#   COCOCOIR_S3_KEY_DIR    — directory containing the pre-generated
#                            access-key-id and secret-access-key files
#                            (sops-nix decrypted at runtime)
#   GARAGE_RPC_SECRET_FILE — path to the RPC secret file (set by systemd
#                            LoadCredential in the unit; required for
#                            the `garage` CLI to authenticate)
set -euo pipefail

usage() {
  sed -n '2,/^# Flags accept/p' "$0" | sed 's/^# \{0,1\}//'
}

GLOBAL_DIR=""
ADDRESS=""
ZONE=""
CAPACITY=""
BUCKETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --global-dir)  GLOBAL_DIR="$2"; shift 2 ;;
    --global-dir=*) GLOBAL_DIR="${1#*=}"; shift ;;
    --address)     ADDRESS="$2"; shift 2 ;;
    --address=*)   ADDRESS="${1#*=}"; shift ;;
    --zone)        ZONE="$2"; shift 2 ;;
    --zone=*)      ZONE="${1#*=}"; shift ;;
    --capacity)    CAPACITY="$2"; shift 2 ;;
    --capacity=*)  CAPACITY="${1#*=}"; shift ;;
    --bucket)      BUCKETS+=("$2"); shift 2 ;;
    --bucket=*)    BUCKETS+=("${1#*=}"); shift ;;
    --help|-h)     usage; exit 0 ;;
    -*) echo "[bucket-init] unknown option: $1" >&2; exit 1 ;;
    *)  BUCKETS+=("$1"); shift ;;
  esac
done

missing=()
[ -z "$GLOBAL_DIR" ] && missing+=("--global-dir")
[ -z "$ADDRESS"    ] && missing+=("--address")
[ -z "$ZONE"       ] && missing+=("--zone")
[ -z "$CAPACITY"   ] && missing+=("--capacity")
[ "${#BUCKETS[@]}" -eq 0 ] && missing+=("at least one --bucket or positional bucket name")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[bucket-init] missing required: ${missing[*]}" >&2
  echo >&2
  usage >&2
  exit 1
fi

case "$GLOBAL_DIR" in
  /*) ;;
  *) echo "[bucket-init] --global-dir must be absolute: $GLOBAL_DIR" >&2; exit 1 ;;
esac

COCOCOIR_S3_KEY_DIR="${COCOCOIR_S3_KEY_DIR:-}"
if [ -z "$COCOCOIR_S3_KEY_DIR" ] || [ ! -d "$COCOCOIR_S3_KEY_DIR" ]; then
  echo "[bucket-init] COCOCOIR_S3_KEY_DIR not set or not a directory" >&2
  exit 1
fi

mkdir -p "$GLOBAL_DIR"
chmod 0700 "$GLOBAL_DIR"

KEY_ID="$(cat "$COCOCOIR_S3_KEY_DIR/access-key-id")"
SECRET="$(cat "$COCOCOIR_S3_KEY_DIR/secret-access-key")"

echo "[bucket-init] waiting for garage admin API..."
ready=0
for _ in $(seq 1 30); do
  if garage -c /etc/garage.toml status >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "[bucket-init] garage admin API not ready after 30s" >&2
  exit 1
fi

local_id="$(garage -c /etc/garage.toml node id 2>/dev/null || true)"
if [ -z "$local_id" ]; then
  echo "[bucket-init] could not get local node ID" >&2
  exit 1
fi
echo "[bucket-init] local node ID: $local_id"

if ! garage -c /etc/garage.toml layout show 2>/dev/null | grep -qF "$local_id"; then
  echo "[bucket-init] local node not in cluster; adding bootstrap_peers to /etc/garage.toml"
  if grep -q '^bootstrap_peers' /etc/garage.toml; then
    sed -i "s|^bootstrap_peers = .*|bootstrap_peers = [\"$local_id\"]|" /etc/garage.toml
  else
    { printf 'bootstrap_peers = ["%s"]\n' "$local_id"; cat /etc/garage.toml; } \
      > /etc/garage.toml.new
    mv /etc/garage.toml.new /etc/garage.toml
  fi
  echo "[bucket-init] restarting garage.service to pick up bootstrap_peers"
  systemctl restart garage

  echo "[bucket-init] waiting for cluster to form after restart..."
  formed=0
  for _ in $(seq 1 30); do
    if garage -c /etc/garage.toml status 2>/dev/null | grep -qF "$ADDRESS"; then
      formed=1
      break
    fi
    sleep 2
  done
  if [ "$formed" -ne 1 ]; then
    echo "[bucket-init] cluster did not form within 60s after restart" >&2
    exit 1
  fi
  echo "[bucket-init] cluster formed"
fi

echo "[bucket-init] local node in cluster, proceeding"

if garage -c /etc/garage.toml layout show 2>/dev/null | grep -qE 'layout version: [1-9]'; then
  echo "[bucket-init] single-node layout already applied"
else
  local_id_short="${local_id%@*}"
  garage -c /etc/garage.toml layout assign \
    --capacity "$CAPACITY" \
    -z "$ZONE" \
    "$local_id_short" >/dev/null
  garage -c /etc/garage.toml layout apply --version 1 >/dev/null
  echo "[bucket-init] applied single-node layout"
fi

if ! garage -c /etc/garage.toml key info "$KEY_ID" >/dev/null 2>&1; then
  garage -c /etc/garage.toml key import --yes \
    "$KEY_ID" "$SECRET" -n cococoir-global >/dev/null
  echo "[bucket-init] imported global S3 key"
else
  echo "[bucket-init] global S3 key already imported"
fi

for NAME in "${BUCKETS[@]}"; do
  if ! garage -c /etc/garage.toml bucket info "$NAME" >/dev/null 2>&1; then
    garage -c /etc/garage.toml bucket create "$NAME" >/dev/null
    echo "[bucket-init] created bucket: $NAME"
  fi
  garage -c /etc/garage.toml bucket allow \
    --read --write "$NAME" --key "$KEY_ID" >/dev/null
done

ln -sf "$COCOCOIR_S3_KEY_DIR/access-key-id" "$GLOBAL_DIR/access-key-id"
ln -sf "$COCOCOIR_S3_KEY_DIR/secret-access-key" "$GLOBAL_DIR/secret-access-key"

echo "[bucket-init] done"
