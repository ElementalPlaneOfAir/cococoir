#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: ensure the local node is in the
# cluster view, apply single-node layout, import the pre-generated
# global S3 key, create buckets, and allow the global key on each.
#
# Order matters:
#   0. wait for admin API + run `garage node connect <self-full-id>`
#      so the local node is in the cluster view. garage 1.3.x does
#      NOT self-bootstrap in the config (we can't put the local
#      node's full `<hex-id>@<ip:port>` ID in `bootstrap_peers`
#      at config time because the ID is derived from `rpc_secret`
#      at first start).
#   1. apply single-node layout (assigns this node to its zone).
#   2. import the pre-generated global S3 key.
#   3. create buckets + allow the global key on each.
#
# Skipping step 0 produces "Error: Internal error: 0 nodes match
# '<self-addr>'" from `layout assign`. Skipping step 1 produces
# "Could not reach quorum of 1 (sets=Some(1)). 0 of 0 request
# succeeded" from `key import` / `bucket create`.
#
# Usage: bucket-init.sh \
#   --global-dir <path> --address <rpc-addr> --zone <zone> \
#   --capacity <cap> --bucket <name> [--bucket <name>...] [<bucket>...]
#
# Required env:
#   CLAN_VAR_S3_KEY_DIR — directory containing the pre-generated
#                         access-key-id and secret-access-key files
#                         (from the garage-global-s3-key clan-core var
#                         generator, SOPS-decrypted at runtime).
#   GARAGE_RPC_SECRET_FILE — path to the RPC secret file (set by systemd
#                            LoadCredential in the unit; required for
#                            the `garage` CLI to authenticate to the
#                            running daemon's admin API).
#
# Flags accept both `--flag value` and `--flag=value` forms. Bucket
# names can be passed positionally OR via repeated `--bucket <name>`.
# Use --help to print this header.
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

# Validate required flags.
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

CLAN_VAR_S3_KEY_DIR="${CLAN_VAR_S3_KEY_DIR:-}"
if [ -z "$CLAN_VAR_S3_KEY_DIR" ] || [ ! -d "$CLAN_VAR_S3_KEY_DIR" ]; then
  echo "[bucket-init] CLAN_VAR_S3_KEY_DIR not set or not a directory" >&2
  exit 1
fi

mkdir -p "$GLOBAL_DIR"
chmod 0700 "$GLOBAL_DIR"

# Read the pre-generated global S3 key (idempotent).
KEY_ID="$(cat "$CLAN_VAR_S3_KEY_DIR/access-key-id")"
SECRET="$(cat "$CLAN_VAR_S3_KEY_DIR/secret-access-key")"

# 0. Wait for the garage admin API to be ready. The systemd unit
#    `After=garage.service` only guarantees the daemon process is
#    up, not that the admin socket on 127.0.0.1:3903 is accepting
#    connections. Poll `garage status` (a cheap, idempotent admin
#    API call) until it succeeds or we time out.
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

# 0b. Ensure the local node is in the cluster view. For single-node
#     deployments, the daemon does not self-bootstrap (we don't set
#     `bootstrap_peers` in the config, since we don't know the local
#     node's full `<hex-id>@<ip:port>` ID at config time). The
#     canonical way to bring an isolated node into the cluster is
#     `garage node connect <self-full-id>` — this makes the local
#     node connect to itself, exchange identities, and register in
#     its own cluster view.
#
#     Get the local node's full ID first (this command does NOT
#     require the admin API — it just reads the local config and
#     prints the ID), then run `node connect` only if the local
#     node isn't already in the layout.
local_id="$(garage -c /etc/garage.toml node id 2>/dev/null || true)"
if [ -z "$local_id" ]; then
  echo "[bucket-init] could not get local node ID" >&2
  exit 1
fi
echo "[bucket-init] local node ID: $local_id"

if garage -c /etc/garage.toml layout show 2>/dev/null | grep -qF "$local_id"; then
  echo "[bucket-init] local node already in cluster layout"
else
  echo "[bucket-init] local node not in cluster; running 'node connect' to self-register"
  connected=0
  for attempt in 1 2 3 4 5; do
    if garage -c /etc/garage.toml node connect "$local_id" >/dev/null 2>&1; then
      connected=1
      break
    fi
    sleep 2
  done
  if [ "$connected" -ne 1 ]; then
    echo "[bucket-init] 'node connect $local_id' failed after 5 attempts" >&2
    exit 1
  fi
  echo "[bucket-init] local node connected to cluster"
fi

# 1. Apply single-node layout. Now that the local node is in the
#    cluster view, `layout assign` will find it. `layout assign` and
#    `layout apply --version 1` are idempotent at the protocol level
#    (re-assigning the same node and applying the same layout version
#    is a no-op), so we run them every time.
if garage -c /etc/garage.toml layout show 2>/dev/null | grep -qF "$local_id"; then
  echo "[bucket-init] single-node layout already applied"
else
  garage -c /etc/garage.toml layout assign \
    --capacity "$CAPACITY" \
    -z "$ZONE" \
    "$local_id" >/dev/null
  garage -c /etc/garage.toml layout apply --version 1 >/dev/null
  echo "[bucket-init] applied single-node layout"
fi

# 2. Import the pre-generated global S3 key. Now that the cluster
#    has at least one node, key import can replicate to quorum.
if ! garage -c /etc/garage.toml key info "$KEY_ID" >/dev/null 2>&1; then
  garage -c /etc/garage.toml key import --yes \
    "$KEY_ID" "$SECRET" -n cococoir-global >/dev/null
  echo "[bucket-init] imported global S3 key"
else
  echo "[bucket-init] global S3 key already imported"
fi

# 3. Create buckets + allow the global key on each.
for NAME in "${BUCKETS[@]}"; do
  if ! garage -c /etc/garage.toml bucket info "$NAME" >/dev/null 2>&1; then
    garage -c /etc/garage.toml bucket create "$NAME" >/dev/null
    echo "[bucket-init] created bucket: $NAME"
  fi
  garage -c /etc/garage.toml bucket allow \
    --read --write "$NAME" --key "$KEY_ID" >/dev/null
done

# 4. Symlink the key files into globalDir for native-S3 clients.
ln -sf "$CLAN_VAR_S3_KEY_DIR/access-key-id" "$GLOBAL_DIR/access-key-id"
ln -sf "$CLAN_VAR_S3_KEY_DIR/secret-access-key" "$GLOBAL_DIR/secret-access-key"

echo "[bucket-init] done"
