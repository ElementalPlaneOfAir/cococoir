#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: ensure the local node is in the
# cluster view, apply single-node layout, import the pre-generated
# global S3 key, create buckets, and allow the global key on each.
#
# Order matters:
#   0. wait for admin API + run `garage node connect <self-addr>` so
#      the local node is in the cluster view (the daemon's
#      `bootstrap_peers = [self]` self-bootstrap is timing-dependent
#      and has been observed to not complete by the time this
#      oneshot runs).
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
#    connections. Poll `garage node list` (a cheap, idempotent call)
#    until it succeeds or we time out.
echo "[bucket-init] waiting for garage admin API..."
ready=0
for _ in $(seq 1 30); do
  if garage -c /etc/garage.toml node list >/dev/null 2>&1; then
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
#     deployments, the daemon's self-bootstrap via `bootstrap_peers =
#     [me.address]` is timing-dependent and has been observed to
#     not complete by the time this oneshot runs (symptom: subsequent
#     `layout assign` returns "0 nodes match '<self-addr>'").
#     `garage node connect <self-addr>` is the authoritative way to
#     make the local node join its own cluster — it's idempotent
#     (re-running on an already-connected node is a no-op) and works
#     regardless of `bootstrap_peers` configuration. Skip if the
#     node is already known.
if garage -c /etc/garage.toml node list 2>/dev/null | grep -qF "$ADDRESS"; then
  echo "[bucket-init] local node already in cluster"
else
  echo "[bucket-init] local node not in cluster; running 'node connect' to self-register"
  connected=0
  for attempt in 1 2 3 4 5; do
    if garage -c /etc/garage.toml node connect "$ADDRESS" >/dev/null 2>&1; then
      connected=1
      break
    fi
    sleep 2
  done
  if [ "$connected" -ne 1 ]; then
    echo "[bucket-init] 'node connect $ADDRESS' failed after 5 attempts" >&2
    exit 1
  fi
  echo "[bucket-init] local node connected to cluster"
fi

# 1. Apply single-node layout. Now that the local node is in the
#    cluster view, `layout assign` will find it. `layout assign` and
#    `layout apply --version 1` are idempotent at the protocol level
#    (re-assigning the same node and applying the same layout version
#    is a no-op), so we run them every time. The previous version of
#    this script gated on `garage layout show`, but that's been
#    observed to return success-with-empty-result on a fresh cluster,
#    causing the gated branch to be skipped and `layout assign` to
#    fail with "0 nodes match" before node connect was added.
if garage -c /etc/garage.toml layout show 2>/dev/null | grep -qF "$ADDRESS"; then
  echo "[bucket-init] single-node layout already applied"
else
  garage -c /etc/garage.toml layout assign \
    --capacity "$CAPACITY" \
    -z "$ZONE" \
    "$ADDRESS" >/dev/null
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
