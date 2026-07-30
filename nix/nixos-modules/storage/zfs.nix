# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/storage — ZFS pool + dataset management.
#
# Always-on (cococoir.storage.enable defaults to true). Every
# service that needs storage auto-declares its datasets via
# cococoir.storage.zfs.datasets.<name>; the customer only sets
# pool name + devices in their top-level config.
#
# Per ADR-023: ZFS mirror replaces Garage+FUSE for v2. Single-node
# ZFS pool with per-service datasets, each with an optional quota.
# restic encrypted offsite backups to follow in a later change.
#
# Pool lifecycle:
#   1. First boot: boot.zfs.extraPools attempts import (fails
#      silently — pool doesn't exist yet). cococoir-zfs-pool-create
#      runs after udev settles, creates the pool, imports it.
#   2. Subsequent boots: boot.zfs.extraPools imports the pool from
#      disk. cococoir-zfs-pool-create is a no-op (pool exists).
#
# Datasets are created idempotently by cococoir-zfs-datasets.
# Services use RequiresMountsFor= on their mountpoints.
{ config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types optionalString concatStringsSep
    concatMapStringsSep mapAttrsToList escapeShellArg;

  cfg = config.cococoir.storage;
  poolName = cfg.zfs.pool.name;
  devices = cfg.zfs.pool.devices;
  layout = cfg.zfs.pool.layout;
  ashift = cfg.zfs.pool.ashift;

  datasetEntries = mapAttrsToList (name: ds: {
    zfsName = "${poolName}/cococoir/${name}";
    mountpoint = ds.mountpoint;
    quota = ds.quota;
    recordsize = ds.recordsize;
  }) cfg.zfs.datasets;

  layoutArg = if layout == "stripe" then " " else "${layout} ";

  poolCreate = pkgs.writeShellScript "cococoir-zfs-pool-create" ''
    set -euo pipefail
    if ${pkgs.zfs}/bin/zpool list -H -o name 2>/dev/null | grep -qx '${poolName}'; then
      echo "[cococoir-zfs] pool ${poolName} already exists"
      exit 0
    fi
    echo "[cococoir-zfs] creating pool ${poolName}"
    ${pkgs.zfs}/bin/zpool create -f \
      -o ashift=${toString ashift} \
      -O mountpoint=none \
      -O compression=lz4 \
      ${poolName} \
      ${layoutArg}${concatStringsSep " " (map escapeShellArg devices)}
  '';

  datasetCreateLine = ds: ''
    if ${pkgs.zfs}/bin/zfs list -H -o name ${ds.zfsName} >/dev/null 2>&1; then
      echo "[cococoir-zfs] dataset ${ds.zfsName} exists"
    else
      echo "[cococoir-zfs] creating dataset ${ds.zfsName}"
      ${pkgs.zfs}/bin/zfs create \
        ${optionalString (ds.mountpoint != "") "-o mountpoint=${escapeShellArg ds.mountpoint}"} \
        ${optionalString (ds.quota != null) "-o quota=${escapeShellArg ds.quota}"} \
        ${optionalString (ds.recordsize != null) "-o recordsize=${escapeShellArg ds.recordsize}"} \
        ${escapeShellArg ds.zfsName}
    fi
  '';

  datasetCreate = pkgs.writeShellScript "cococoir-zfs-dataset-create" ''
    set -euo pipefail
    ${concatMapStringsSep "\n" datasetCreateLine datasetEntries}
  '';

  mountpoints = map (ds: ds.mountpoint) datasetEntries;
in
{
  options.cococoir.storage = {
    enable = mkOption {
      type = types.bool;
      default = true;
      defaultText = "true";
      description = ''
        Enable the cococoir storage layer (ZFS pool + datasets).
        **Always on** — the platform requires storage for every
        service that has data. Customers do not need to set this
        option; it is `true` by default. Set to `false` only in
        a non-customer config (e.g. an edge-only VPS test).
      '';
    };

    zfs = {
      pool = {
        name = mkOption {
          type = types.str;
          default = "tank";
          description = "ZFS pool name.";
        };

        layout = mkOption {
          type = types.enum ["mirror" "raidz" "raidz2" "stripe"];
          default = "mirror";
          description = "ZFS vdev layout.";
        };

        devices = mkOption {
          type = types.listOf types.path;
          default = [];
          example = [
            "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E1234567"
            "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E7654321"
          ];
          description = ''
            Block devices for the ZFS pool. Use /dev/disk/by-id
            paths for stable disk identification across reboots.
          '';
        };

        ashift = mkOption {
          type = types.ints.between 9 16;
          default = 12;
          description = "ZFS ashift (12 = 4K sector drives).";
        };
      };

      datasets = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            mountpoint = mkOption {
              type = types.str;
              description = "Filesystem mountpoint for this dataset.";
            };

            quota = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "2T";
              description = "ZFS quota (null = unlimited).";
            };

            recordsize = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "1M";
              description = "ZFS recordsize (null = pool default).";
            };
          };
        });
        default = {};
        description = ''
          ZFS datasets to create under <pool>/cococoir/.
          Service modules auto-declare their datasets here so
          the customer does not have to wire storage manually.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = devices != [];
        message = ''
          cococoir.storage: zfs.pool.devices is empty.
          Set block device paths (use /dev/disk/by-id for
          stable identification).
          Example:
            cococoir.storage.zfs.pool.devices = [
              "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-XXXX"
              "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-YYYY"
            ];
        '';
      }
    ];

    boot.supportedFilesystems = ["zfs"];
    boot.zfs.extraPools = [poolName];

    networking.hostId = lib.mkDefault
      (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));

    services.zfs.autoScrub.enable = true;

    environment.systemPackages = [pkgs.zfs];

    systemd.services.cococoir-zfs-pool-create = {
      description = "cococoir ZFS pool creation (idempotent)";
      wantedBy = ["multi-user.target"];
      after = ["systemd-udev-settle.service"];
      wants = ["systemd-udev-settle.service"];
      before = ["cococoir-zfs-datasets.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = poolCreate;
      };
      path = [pkgs.zfs pkgs.gnugrep pkgs.coreutils];
    };

    systemd.services.cococoir-zfs-datasets = {
      description = "cococoir ZFS dataset creation (idempotent)";
      wantedBy = ["multi-user.target"];
      after = ["cococoir-zfs-pool-create.service"];
      requires = ["cococoir-zfs-pool-create.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = datasetCreate;
      };
      path = [pkgs.zfs pkgs.coreutils];
    };
  };
}
