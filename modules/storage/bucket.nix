# SPDX-License-Identifier: MIT
{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.storage;
  garagePackage = pkgs.garage_2;
  enabledBuckets = lib.filter (b: b.enable) (lib.attrValues cfg.buckets);
  numZonesWithCapacity = builtins.length (lib.filter
    (z: z.capacity != null && z.capacity != 0)
    cfg.cluster.layout.zones);

  # RF clamping computed here, used both for assertions (in storage.nix)
  # and for the bucket-init script.
  clampRF = rf:
    if rf <= numZonesWithCapacity then rf
    else if numZonesWithCapacity == 0 then 1
    else numZonesWithCapacity;

  bucketInitScript = pkgs.writeShellScript "garage-bucket-init" ''
    set -euo pipefail
    . /etc/cococoir/garage.env

    mkdir -p "$COCOCOIR_BUCKETS_DIR" "$COCOCOIR_GLOBAL_KEY_DIR"

    ADMIN="$GARAGE_ADMIN_URL"
    GCALL() { $GARAGE_BIN --admin-address "$ADMIN" "$@"; }

    # Wait for admin API to be reachable (max 60s)
    for i in $(seq 1 60); do
      if GCALL status >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if ! GCALL status >/dev/null 2>&1; then
      echo "garage admin API not reachable after 60s" >&2
      exit 1
    fi

    # ── 1. Cluster-wide global key ──────────────────────────────────────────
    # The user picked "one global key" for the cluster (vs per-bucket keys).
    # The keypair is generated once on first deploy and persisted under
    # $COCOCOIR_GLOBAL_KEY_DIR.
    GLOBAL_KEYID_FILE="$COCOCOIR_GLOBAL_KEY_DIR/access-key-id"
    GLOBAL_SECRET_FILE="$COCOCOIR_GLOBAL_KEY_DIR/secret-access-key"

    if [ -f "$GLOBAL_KEYID_FILE" ] && [ -f "$GLOBAL_SECRET_FILE" ]; then
      GLOBAL_KEY_ID=$(cat "$GLOBAL_KEYID_FILE")
      echo "global key already exists: $GLOBAL_KEY_ID"
    else
      CREATE_OUT=$(GCALL key create --name "$GARAGE_NODE_ID-cluster-global" 2>&1) || true
      GLOBAL_KEY_ID=$(echo "$CREATE_OUT" | ${pkgs.gnugrep}/bin/grep -oE 'Key ID:[[:space:]]*[A-Za-z0-9_-]+' | head -1 | awk '{print $3}')
      GLOBAL_SECRET=$(echo "$CREATE_OUT" | ${pkgs.gnugrep}/bin/grep -oE 'Secret key:[[:space:]]*[A-Za-z0-9_-]+' | head -1 | awk '{print $3}')
      if [ -z "$GLOBAL_KEY_ID" ] || [ -z "$GLOBAL_SECRET" ]; then
        echo "failed to parse global key creation output" >&2
        echo "$CREATE_OUT" >&2
        exit 1
      fi
      echo "$GLOBAL_KEY_ID" > "$GLOBAL_KEYID_FILE"
      echo "$GLOBAL_SECRET" > "$GLOBAL_SECRET_FILE"
      chmod 0600 "$GLOBAL_KEYID_FILE" "$GLOBAL_SECRET_FILE"
      echo "global key created: $GLOBAL_KEY_ID"
    fi

    # ── 2. Per-bucket: create + apply RF + website/quotas ───────────────────
    ${lib.concatMapStrings (b: ''
      BUCKET="${b.name}"
      BDIR="$COCOCOIR_BUCKETS_DIR/$BUCKET"
      mkdir -p "$BDIR"

      if ! GCALL bucket info "$BUCKET" >/dev/null 2>&1; then
        GCALL bucket create "$BUCKET"
      fi

      INTENDED_RF=${toString b.replicationFactor}
      CLAMPED_RF=${toString (clampRF b.replicationFactor)}
      if [ "$INTENDED_RF" != "$CLAMPED_RF" ]; then
        echo "WARNING: bucket $BUCKET RF clamped from $INTENDED_RF to $CLAMPED_RF (cluster topology)" >&2
      fi
      GCALL bucket layout --apply "$BUCKET" --replication-factor "$CLAMPED_RF" 2>&1 || true

      # Allow the global key to read+write this bucket
      GCALL bucket allow --read  --key "$GLOBAL_KEY_ID" "$BUCKET" 2>&1 || true
      GCALL bucket allow --write --key "$GLOBAL_KEY_ID" "$BUCKET" 2>&1 || true

      # Quotas
      ${lib.optionalString (b.quotas != null && (b.quotas.maxSize != null || b.quotas.maxObjects != null)) ''
        QARGS=""
        ${lib.optionalString (b.quotas.maxSize != null) ''QARGS="$QARGS --max-size ${toString b.quotas.maxSize}"''}
        ${lib.optionalString (b.quotas.maxObjects != null) ''QARGS="$QARGS --max-objects ${toString b.quotas.maxObjects}"''}
        GCALL bucket set-quotas $QARGS "$BUCKET" 2>&1 || true
      ''}

      # Website hosting
      ${lib.optionalString (b.website != null) ''
        GCALL bucket website --allow "$BUCKET" \
          --index-document "${b.website.index}" \
          --error-document "${b.website.error}" 2>&1 || true
      ''}
    '') enabledBuckets}

    echo "garage bucket init complete"
  '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.garage-bucket-init = {
      description = "Provision Cococoir buckets, global key, and per-bucket RF";
      wantedBy = [ "multi-user.target" ];
      after = [ "garage.service" ];
      requires = [ "garage.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
      script = bucketInitScript;
    };
  };
}
