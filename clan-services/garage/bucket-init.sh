#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: import the pre-generated global S3 key,
# apply single-node layout, create buckets, and allow the global key
# on each.
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

# Import the pre-generated global S3 key (idempotent).
KEY_ID="$(cat "$CLAN_VAR_S3_KEY_DIR/access-key-id")"
SECRET="$(cat "$CLAN_VAR_S3_KEY_DIR/secret-access-key")"

if ! garage -c /etc/garage.toml key info "$KEY_ID" >/dev/null 2>&1; then
  garage -c /etc/garage.toml key import --yes \
    "$KEY_ID" "$SECRET" -n cococoir-global >/dev/null
  echo "[bucket-init] imported global S3 key"
else
  echo "[bucket-init] global S3 key already imported"
fi

# Symlink the key files into globalDir for native-S3 clients.
ln -sf "$CLAN_VAR_S3_KEY_DIR/access-key-id" "$GLOBAL_DIR/access-key-id"
ln -sf "$CLAN_VAR_S3_KEY_DIR/secret-access-key" "$GLOBAL_DIR/secret-access-key"

# Apply single-node layout if not yet applied.
if ! garage -c /etc/garage.toml layout show >/dev/null 2>&1; then
  garage -c /etc/garage.toml layout assign \
    --capacity "$CAPACITY" \
    -z "$ZONE" \
    "$ADDRESS" >/dev/null
  garage -c /etc/garage.toml layout apply --version 1 >/dev/null
  echo "[bucket-init] applied single-node layout"
fi

# Create buckets + allow the global key.
for NAME in "${BUCKETS[@]}"; do
  if ! garage -c /etc/garage.toml bucket info "$NAME" >/dev/null 2>&1; then
    garage -c /etc/garage.toml bucket create "$NAME" >/dev/null
    echo "[bucket-init] created bucket: $NAME"
  fi
  garage -c /etc/garage.toml bucket allow \
    --read --write "$NAME" --key "$KEY_ID" >/dev/null
done

echo "[bucket-init] done"
