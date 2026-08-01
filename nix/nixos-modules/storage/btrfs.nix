# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/storage — btrfs pool + subvolume management.
#
# Always-on (cococoir.storage.enable defaults to true). Every
# service that needs storage auto-declares its subvolumes via
# cococoir.storage.btrfs.subvolumes.<name>; the customer only
# sets pool name + devices in their top-level config.
#
# Per ADR-023: btrfs replaces Garage+FUSE for v2. Single-node
# btrfs pool with per-service subvolumes, each with an optional
# quota. restic encrypted offsite backups to follow.
#
# btrfs was chosen over ZFS because:
#   - Arbitrary drive sizes can be added/removed at any time
#     (btrfs device add, btrfs device remove, btrfs replace)
#   - Mixed drive sizes work (btrfs RAID1 distributes 2 copies
#     across any 2 devices, not fixed-size mirror pairs)
#   - Per-subvolume profiles possible via metadata block groups
#
# Pool lifecycle:
#   1. cococoir-btrfs-pool (oneshot) formats the btrfs on first
#      boot (idempotent -- checks blkid before mkfs).
#   2. fileSystems entry mounts the pool by LABEL at /data, with
#      x-systemd.requires/after on the pool creation service.
#   3. cococoir-btrfs-subvolumes (oneshot) creates per-service
#      subvolumes idempotently after the mount is ready.
#   4. Services use unitConfig.RequiresMountsFor on their subvolume
#      paths so they wait for the mountpoint before starting.
{ config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types optionalString concatMapStringsSep
    mapAttrsToList escapeShellArg;

  cfg = config.cococoir.storage;
  label = cfg.btrfs.pool.name;
  devices = cfg.btrfs.pool.devices;
  layout = cfg.btrfs.pool.layout;
  mountpoint = cfg.btrfs.pool.mountpoint;

  dataProfile = {
    mirror = "raid1";
    stripe = "single";
  }.${layout};

  metadataProfile = {
    mirror = "raid1";
    stripe = "raid1";
  }.${layout};

  poolCreate = pkgs.writeShellScript "cococoir-btrfs-pool-create" ''
    set -euo pipefail
    for dev in ${concatMapStringsSep " " escapeShellArg devices}; do
      if ${pkgs.util-linux}/bin/blkid -s TYPE -o value "$dev" 2>/dev/null | grep -qx btrfs; then
        echo "[cococoir-btrfs] pool already exists on $dev"
        exit 0
      fi
    done
    echo "[cococoir-btrfs] creating pool ${label} on ${toString devices}"
    ${pkgs.btrfs-progs}/bin/mkfs.btrfs -f \
      -L ${escapeShellArg label} \
      -d ${dataProfile} \
      -m ${metadataProfile} \
      ${concatMapStringsSep " " escapeShellArg devices}
  '';

  subvolumeEntries = mapAttrsToList (name: sv: {
    path = sv.mountpoint;
    quota = sv.quota;
    owner = sv.owner;
  }) cfg.btrfs.subvolumes;

  subvolumeCreateLine = sv: ''
    echo "[cococoir-btrfs] subvolume ${sv.path}"
    ${pkgs.btrfs-progs}/bin/btrfs subvolume show ${escapeShellArg sv.path} >/dev/null 2>&1 && \
      { echo "  -> already exists"; } || \
      {
        echo "  -> creating"
        ${pkgs.coreutils}/bin/mkdir -p "$(dirname ${escapeShellArg sv.path})"
        ${pkgs.btrfs-progs}/bin/btrfs subvolume create ${escapeShellArg sv.path}
        ${optionalString (sv.quota != null) ''
          ${pkgs.btrfs-progs}/bin/btrfs qgroup limit ${escapeShellArg sv.quota} ${escapeShellArg sv.path}
        ''}
      }
    ${optionalString (sv.owner != null) ''
      ${pkgs.coreutils}/bin/chown ${escapeShellArg (sv.owner.user + (if sv.owner.group != null then ":" + sv.owner.group else ""))} ${escapeShellArg sv.path}
      ${optionalString (sv.owner.mode != null) ''
        ${pkgs.coreutils}/bin/chmod ${escapeShellArg sv.owner.mode} ${escapeShellArg sv.path}
      ''}
    ''}
  '';

  subvolumeCreate = pkgs.writeShellScript "cococoir-btrfs-subvolume-create" ''
    set -euo pipefail
    ${pkgs.btrfs-progs}/bin/btrfs quota enable ${escapeShellArg mountpoint} 2>/dev/null || true
    ${concatMapStringsSep "\n" subvolumeCreateLine subvolumeEntries}
  '';
in
{
  options.cococoir.storage = {
    enable = mkOption {
      type = types.bool;
      default = true;
      defaultText = "true";
      description = ''
        Enable the cococoir storage layer (btrfs pool + subvolumes).
        **Always on** -- the platform requires storage for every
        service that has data. Customers do not need to set this
        option; it is `true` by default. Set to `false` only in
        a non-customer config (e.g. an edge-only VPS test).
      '';
    };

    btrfs = {
      pool = {
        name = mkOption {
          type = types.str;
          default = "tank";
          description = "btrfs filesystem label. Used for mount by LABEL.";
        };

        mountpoint = mkOption {
          type = types.path;
          default = "/data";
          description = "Where to mount the btrfs pool. All service subvolumes are created under this path.";
        };

        layout = mkOption {
          type = types.enum ["mirror" "stripe"];
          default = "mirror";
          description = ''
            btrfs data profile. mirror = RAID1 (2 copies, survives 1
            drive failure). stripe = single (1 copy, no redundancy
            for data; metadata is still RAID1 so the pool stays
            online after a drive failure).
          '';
        };

        devices = mkOption {
          type = types.listOf types.path;
          default = [];
          example = [
            "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E1234567"
            "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E7654321"
          ];
          description = ''
            Block devices for the btrfs pool. Use /dev/disk/by-id
            paths for stable disk identification across reboots.
            btrfs can add/remove/replace devices at any time;
            drives do not need to be the same size.
          '';
        };
      };

      subvolumes = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            mountpoint = mkOption {
              type = types.str;
              description = "Absolute path for this subvolume within the btrfs pool.";
            };

            quota = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "2T";
              description = "btrfs qgroup size limit. null = unlimited.";
            };

            owner = mkOption {
              type = types.nullOr (types.submodule {
                options = {
                  user = mkOption {
                    type = types.str;
                    description = "System user that owns the subvolume (the service's runtime user).";
                  };
                  group = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Owning group. Defaults to the user's primary group when null.";
                  };
                  mode = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "770";
                    description = "Permission bits applied at creation. null = leave btrfs default.";
                  };
                };
              });
              default = null;
              description = ''
                Ownership applied to the subvolume at creation (and on
                every boot, so existing pools converge). Services that
                write data must own their subvolume; subvolumes created
                root:root 0755 are read-only to the service's runtime
                user, which breaks any service that persists data.
              '';
            };
          };
        });
        default = {};
        description = ''
          btrfs subvolumes to create under the pool mountpoint.
          Service modules auto-declare their subvolumes here so
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
          cococoir.storage: btrfs.pool.devices is empty.
          Set block device paths (use /dev/disk/by-id for
          stable identification).
          Example:
            cococoir.storage.btrfs.pool.devices = [
              "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-XXXX"
              "/dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-YYYY"
            ];
        '';
      }
    ];

    boot.supportedFilesystems = ["btrfs"];

    environment.systemPackages = [pkgs.btrfs-progs];

    services.btrfs.autoScrub = {
      enable = true;
      fileSystems = [mountpoint];
    };

    systemd.mounts = [{
      where = mountpoint;
      what = "LABEL=${label}";
      type = "btrfs";
      options = "defaults,compress=zstd";
      wantedBy = ["local-fs.target"];
      before = ["local-fs.target"];
      after = ["cococoir-btrfs-pool.service"];
      requires = ["cococoir-btrfs-pool.service"];
    }];

    systemd.services.cococoir-btrfs-pool = {
      description = "cococoir btrfs pool creation (idempotent)";
      wantedBy = ["local-fs.target"];
      before = ["local-fs.target"];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = poolCreate;
      };
      path = [pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils];
    };

    systemd.services.cococoir-btrfs-subvolumes = {
      description = "cococoir btrfs subvolume creation (idempotent)";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      unitConfig.RequiresMountsFor = mountpoint;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = subvolumeCreate;
      };
      path = [pkgs.btrfs-progs pkgs.coreutils];
    };
  };
}
