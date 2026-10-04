# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/storage/plain-dirs — the non-btrfs storage backend.
#
# A target without btrfs (e.g. the Mac/Windows VM, or a plain host
# volume) runs the same fortress modules with `fortress.storage.
# backend = "plain-dirs"`: the service modules' auto-declared
# subvolumes (fortress.storage.btrfs.subvolumes — the same tree the
# btrfs backend consumes) are applied as plain directories under
# `fortress.storage.dataRoot` with the same owner/mode semantics
# (systemd-tmpfiles re-applies owner/mode on every boot, matching
# the btrfs backend's converge-on-boot behavior). Persistence
# comes from the host bind-mounting a volume at dataRoot.
#
# Quotas: a btrfs concept. The service modules auto-declare them
# (mkDefault) for the customer (btrfs) tier; this backend ignores
# them by design — size enforcement on a plain volume is the host
# volume's job, not a per-service qgroup.
{
  config,
  lib,
  ...
}: let
  cfg = config.fortress.storage;

  modeStr = mode:
    if mode == null then "-" else "0${mode}";
  userStr = owner: owner.user;
  groupStr = owner:
    if owner.group == null then "-" else owner.group;

  # tmpfiles "d" rules create the directory if missing and
  # re-apply owner/mode on every boot (same converge-on-boot
  # semantics as the btrfs backend's subvolume owner application).
  subvolumeRules =
    lib.concatLists
    (lib.mapAttrsToList (_: sv:
      lib.optional (sv.owner != null)
        "d ${sv.mountpoint} ${modeStr sv.owner.mode} ${userStr sv.owner} ${groupStr sv.owner}"
      ++ lib.mapAttrsToList (path: d:
        "d ${path} ${modeStr d.mode} ${userStr d} ${groupStr d}")
      sv.dirs)
    cfg.btrfs.subvolumes);
in {
  config = lib.mkIf (cfg.enable && cfg.backend == "plain-dirs") {
    systemd.tmpfiles.rules = subvolumeRules;
  };
}
