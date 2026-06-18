#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: apply single-node layout, import the
# pre-generated global S3 key, create buckets, and allow the global
# key on each.
#
# Order matters: the layout (which assigns this node to a zone) must
# be applied BEFORE any cluster operation that needs to reach a quorum
# (key import, bucket create). Otherwise you get
# "Could not reach quorum of 1 (sets=Some(1)). 0 of 0 request
# succeeded" — the local node isn't in its own cluster view yet.
# Layout apply puts it there.
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

# 1. Apply single-node layout. This is what adds the local node to
#    its own cluster view — without it, every subsequent cluster
#    operation (key import, bucket create) returns
#    "Could not reach quorum of 1 (sets=Some(1)). 0 of 0 request
#    succeeded". `layout assign` and `layout apply` are idempotent
#    at the protocol level (re-assigning the same node and applying
#    the same layout version is a no-op), so we run them every time
#    instead of gating on `garage layout show` (which has been
#    observed to return success-with-empty-result on a fresh cluster,
#    causing the gated branch to be skipped and the layout never
#    applied). Belt and braces: also detect the special case where
#    layout is already up-to-date and log a cleaner message.
if ! garage -c /etc/garage.toml layout show >/dev/null 2>&1 \
   || ! garage -c /etc/garage.toml layout show 2>/dev/null | grep -q "$ADDRESS"; then
  garage -c /etc/garage.toml layout assign \
    --capacity "$CAPACITY" \
    -z "$ZONE" \
    "$ADDRESS" >/dev/null
  garage -c /etc/garage.toml layout apply --version 1 >/dev/null
  echo "[bucket-init] applied single-node layout"
else
  echo "[bucket-init] single-node layout already applied"
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
