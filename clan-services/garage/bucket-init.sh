#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: import the pre-generated global S3 key,
# apply single-node layout, create buckets, and allow the global key
# on each.
#
# Usage: garage-bucket-init <buckets.json> <global-dir>
#
# Required env:
#   CLAN_VAR_S3_KEY_DIR — directory containing the pre-generated
#                         access-key-id and secret-access-key files
#                         (from the garage-global-s3-key clan-core var
#                         generator).
set -euo pipefail

BUCKETS_JSON="${1:-}"
GLOBAL_DIR="${2:-/var/lib/cococoir/garage/global}"
CLAN_VAR_S3_KEY_DIR="${CLAN_VAR_S3_KEY_DIR:-}"

if [ -z "$BUCKETS_JSON" ] || [ ! -r "$BUCKETS_JSON" ]; then
  echo "[bucket-init] buckets.json not readable: $BUCKETS_JSON" >&2
  exit 1
fi
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
    --capacity "$(jq -r .capacity "$BUCKETS_JSON")" \
    -z "$(jq -r .zone "$BUCKETS_JSON")" \
    "$(jq -r .address "$BUCKETS_JSON")" >/dev/null
  garage -c /etc/garage.toml layout apply --version 1 >/dev/null
  echo "[bucket-init] applied single-node layout"
fi

# Create buckets + allow the global key.
jq -r '.buckets[]' "$BUCKETS_JSON" | while read -r NAME; do
  if ! garage -c /etc/garage.toml bucket info "$NAME" >/dev/null 2>&1; then
    garage -c /etc/garage.toml bucket create "$NAME" >/dev/null
    echo "[bucket-init] created bucket: $NAME"
  fi
  garage -c /etc/garage.toml bucket allow \
    --read --write "$NAME" --key "$KEY_ID" >/dev/null
done

echo "[bucket-init] done"
