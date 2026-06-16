#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/garage bucket-init.
# Idempotent first-boot setup: global S3 key, single-node layout,
# buckets + per-bucket allow / quotas / website.
#
# Usage: garage-bucket-init <buckets.json> <global-dir>
set -euo pipefail

BUCKETS_JSON="${1:-}"
GLOBAL_DIR="${2:-/var/lib/cococoir/garage/global}"

if [ -z "$BUCKETS_JSON" ] || [ ! -r "$BUCKETS_JSON" ]; then
  echo "[bucket-init] buckets.json not readable: $BUCKETS_JSON" >&2
  exit 1
fi

mkdir -p "$GLOBAL_DIR"
chmod 0700 "$GLOBAL_DIR"

# Generate or read the global S3 access key.
if [ ! -s "$GLOBAL_DIR/access-key-id" ]; then
  KEY_OUT="$(garage -c /etc/garage.toml key create cococoir-global 2>&1)" || {
    echo "[bucket-init] garage key create failed:" >&2
    echo "$KEY_OUT" >&2
    exit 1
  }
  KEY_ID="$(printf '%s\n' "$KEY_OUT" | awk '/^Key ID:/ {print $3}')"
  SECRET="$(printf '%s\n' "$KEY_OUT" | awk '/^Secret key:/ {print $3}')"
  if [ -z "$KEY_ID" ] || [ -z "$SECRET" ]; then
    echo "[bucket-init] failed to parse key from garage output:" >&2
    echo "$KEY_OUT" >&2
    exit 1
  fi
  printf '%s' "$KEY_ID" > "$GLOBAL_DIR/access-key-id"
  printf '%s' "$SECRET" > "$GLOBAL_DIR/secret-access-key"
  chmod 0600 "$GLOBAL_DIR/secret-access-key"
  chmod 0600 "$GLOBAL_DIR/access-key-id"
  echo "[bucket-init] generated global S3 key"
else
  echo "[bucket-init] reusing existing global S3 key"
fi
KEY_ID="$(cat "$GLOBAL_DIR/access-key-id")"

# Apply single-node layout if not yet applied.
if ! garage -c /etc/garage.toml layout show >/dev/null 2>&1; then
  garage -c /etc/garage.toml layout assign \
    --capacity "$(jq -r .capacity "$BUCKETS_JSON")" \
    -z "$(jq -r .zone "$BUCKETS_JSON")" \
    "$(jq -r .address "$BUCKETS_JSON")" >/dev/null
  garage -c /etc/garage.toml layout apply --version 1 >/dev/null
  echo "[bucket-init] applied single-node layout"
fi

# Create buckets + allow the global key, set quotas, enable website.
jq -c '.buckets | to_entries[] | select(.value.enable)' "$BUCKETS_JSON" | while read -r entry; do
  NAME="$(printf '%s' "$entry" | jq -r '.key')"
  QUOTAS="$(printf '%s' "$entry" | jq -r '.value.quotas // empty')"
  WEBSITE="$(printf '%s' "$entry" | jq -r '.value.website // false')"

  if ! garage -c /etc/garage.toml bucket info "$NAME" >/dev/null 2>&1; then
    garage -c /etc/garage.toml bucket create "$NAME" >/dev/null
    echo "[bucket-init] created bucket: $NAME"
  fi
  garage -c /etc/garage.toml bucket allow \
    --read --write "$NAME" --key "$KEY_ID" >/dev/null

  if [ -n "$QUOTAS" ]; then
    garage -c /etc/garage.toml bucket set-quota "$NAME" "$QUOTAS" >/dev/null || true
  fi
  if [ "$WEBSITE" = "true" ]; then
    garage -c /etc/garage.toml bucket website "$NAME" --allow >/dev/null || true
  fi
done

echo "[bucket-init] done"
