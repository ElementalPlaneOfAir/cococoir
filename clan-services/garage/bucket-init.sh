#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: ensure the local node is in the
# cluster view, apply single-node layout, import the pre-generated
# global S3 key, create buckets, and allow the global key on each.
#
# Order matters:
#   0. wait for admin API.
#   1. get local node's full ID (no admin API needed; the ID is
#      derived from rpc_secret on first start and stored in the
#      metadata dir).
#   2. check if local node is in the cluster. If NOT, this is
#      first boot: write `bootstrap_peers = [<self-full-id>]`
#      to /etc/garage.toml, `systemctl restart garage`, and
#      wait for the local node to self-bootstrap via the new
#      bootstrap_peers (poll `garage layout show` for up to
#      60s). Then fall through to step 3.
#   3. apply single-node layout (assigns this node to its zone).
#   4. import the pre-generated global S3 key.
#   5. create buckets + allow the global key on each.
#
# Why step 2's "edit /etc/garage.toml + restart" approach is
# needed: garage 1.3.x requires `bootstrap_peers` to include the
# local node's full `<hex-id>@<ip:port>` ID for the daemon to
# self-bootstrap. We don't know the local node's ID at NixOS
# config evaluation time (it's generated from `rpc_secret` on
# first start), so the cococoir config deliberately omits
# bootstrap_peers. We tried `garage node connect <self-id>` from
# this script as an alternative, but in practice the CLI returns
# exit 0 without actually adding the local node to its own
# cluster view (the "connected" message is misleading — the
# cluster stays at 0 nodes, and `layout assign` still fails with
# "0 nodes match"). The canonical fix per the garage docs is to
# put the full ID in `bootstrap_peers` and restart.
#
# The cococoir unit uses PartOf=garage.service (NOT Requires=)
# because the script calls `systemctl restart garage` from
# inside this service. Requires= would cascade a restart back
# to this service and kill it mid-execution (we observed this:
# SIGTERM after restart, then start-limit-hit after 5 retries).
# PartOf= propagates start/stop but NOT restart, so the script
# can restart garage and keep running through the cluster-form
# wait and the rest of the init in the same invocation.
#
# Note: this edit to /etc/garage.toml is NOT persisted across
# `nixos-rebuild switch` invocations (the cococoir config
# doesn't carry bootstrap_peers), so this script will re-add
# it after every rebuild. The local node's ID is stable
# (stored in the metadata dir), so on the second+ runs the
# cluster rejoins automatically from the stored cluster state
# and the script skips step 2.
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

# 1. Get the local node's full ID. This command does NOT require
#    the admin API — it just reads the local config and prints the
#    ID (derived from rpc_secret on first start, then stored in
#    the metadata dir; stable across restarts).
local_id="$(garage -c /etc/garage.toml node id 2>/dev/null || true)"
if [ -z "$local_id" ]; then
  echo "[bucket-init] could not get local node ID" >&2
  exit 1
fi
echo "[bucket-init] local node ID: $local_id"

# 2. Check if the local node is in the cluster. If YES, skip to
#    step 3 (layout apply). If NO, this is first boot (or a
#    post-nixos-rebuild fresh start): write bootstrap_peers to
#    /etc/garage.toml, restart garage, wait for the new
#    garage.service to come up and self-bootstrap via the new
#    bootstrap_peers, then fall through to step 3.
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

  # Wait for the new garage.service to come up and the local
  # node to join its own cluster via the newly-added
  # bootstrap_peers. The self-bootstrap (local node connecting
  # to itself) is async, so we poll the admin API. We use
  # PartOf= (not Requires=) for this service so the restart
  # above doesn't cascade-kill this script — we want to keep
  # running through the cluster-form wait and the rest of
  # the script in the same invocation.
  echo "[bucket-init] waiting for cluster to form after restart..."
  formed=0
  for _ in $(seq 1 30); do
    if garage -c /etc/garage.toml layout show 2>/dev/null | grep -qF "$local_id"; then
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

# 3. Apply single-node layout. `layout assign` and `layout apply
#    --version 1` are idempotent at the protocol level
#    (re-assigning the same node and applying the same layout
#    version is a no-op), so we run them every time. The layout
#    gate on `layout show` is for cleaner log output.
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
