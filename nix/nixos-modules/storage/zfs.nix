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
# Pool lifecycle (disko integration):
#   1. disko creates the ZFS pool in the initrd on first boot
#      (format mode). Idempotent — skips if pool already exists.
#   2. boot.zfs.extraPools imports the pool on every boot.
#   3. cococoir-zfs-datasets creates per-service ZFS datasets
#      idempotently after multi-user.target.
#   4. Services use RequiresMountsFor= on their mountpoints.
#
# Disko owns the disk→pool translation (partitioning, ashift,
# vdev layout). This module owns the application layer: dataset
# auto-declarations from service modules, contract assertions,
# hostId, auto-scrub.
{ config,
  lib,
  pkgs,
  options,
  ...
}:
let
  inherit (lib) mkOption types optionalString concatMapStringsSep
    mapAttrsToList escapeShellArg imap1 optionalAttrs;

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

  datasetCreateLine = ds: ''
    if ${pkgs.zfs}/bin/zfs list -H -o name ${ds.zfsName} >/dev/null 2>&1; then
      echo "[cococoir-zfs] dataset ${ds.zfsName} exists"
    else
      echo "[cococoir-zfs] creating dataset ${ds.zfsName}"
      ${pkgs.zfs}/bin/zfs create -p \
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

  diskoDisks = builtins.listToAttrs (imap1 (i: dev: {
    name = "zfs${toString i}";
    value = {
      type = "disk";
      device = dev;
      content = {
        type = "zfs";
        pool = poolName;
      };
    };
  }) devices);
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

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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

      boot.initrd.systemd.enable = true;
      boot.supportedFilesystems = ["zfs"];
      boot.zfs.extraPools = [poolName];
      boot.zfs.forceImportRoot = false;

      networking.hostId = lib.mkDefault
        (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));

      services.zfs.autoScrub.enable = true;

      environment.systemPackages = [pkgs.zfs];

      systemd.services.cococoir-zfs-datasets = {
        description = "cococoir ZFS dataset creation (idempotent)";
        wantedBy = ["multi-user.target"];
        after = ["zfs-import.target"];
        wants = ["zfs-import.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = datasetCreate;
        };
        path = [pkgs.zfs pkgs.coreutils];
      };
    })

    (lib.optionalAttrs (options ? disko) {
      disko.devices = lib.mkIf cfg.enable {
        disk = diskoDisks;
        zpool.${poolName} = {
          type = "zpool";
          options.ashift = toString ashift;
          rootFsOptions = {
            mountpoint = "none";
            compression = "lz4";
          };
        } // optionalAttrs (layout != "stripe") {
          mode = layout;
        };
      };
    })
  ];
}
