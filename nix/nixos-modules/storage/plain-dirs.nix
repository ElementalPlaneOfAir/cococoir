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
# (the `fortress-plain-dirs` unit re-applies owner/mode on every boot,
# matching the btrfs backend's converge-on-boot behavior). Persistence
# comes from the host bind-mounting a volume at dataRoot.
#
# Why a unit and not `systemd.tmpfiles.rules`: the applier installs
# unit files only and never applies tmpfiles (ADR-035 amendment), so a
# tmpfiles rule is silently absent on a customer box and the service's
# data dirs never exist. The btrfs backend already creates its dirs from
# a unit (`fortress-btrfs-subvolumes`); this mirrors it.
#
# Quotas: a btrfs concept. The service modules auto-declare them
# (mkDefault) for the customer (btrfs) tier; this backend ignores
# them by design — size enforcement on a plain volume is the host
# volume's job, not a per-service qgroup.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.fortress.storage;

  dirEntries =
    lib.concatLists
    (lib.mapAttrsToList (_: sv:
      lib.optional (sv.owner != null) {path = sv.mountpoint; owner = sv.owner;}
      ++ lib.mapAttrsToList (path: d: {inherit path; owner = d;}) sv.dirs)
    cfg.btrfs.subvolumes);

  createDir = {path, owner}: ''
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg path}
    ${pkgs.coreutils}/bin/chown ${lib.escapeShellArg (owner.user + (if owner.group != null then ":" + owner.group else ""))} ${lib.escapeShellArg path}
    ${lib.optionalString (owner.mode != null) ''
      ${pkgs.coreutils}/bin/chmod ${lib.escapeShellArg owner.mode} ${lib.escapeShellArg path}
    ''}
  '';

  createScript = pkgs.writeShellScript "fortress-plain-dirs" ''
    set -euo pipefail
    ${lib.concatMapStringsSep "\n" createDir dirEntries}
  '';
in {
  config = lib.mkIf (cfg.enable && cfg.backend == "plain-dirs") {
    systemd.services.fortress-plain-dirs = {
      description = "fortress plain-dirs directory creation (idempotent)";
      # The applier starts exactly `fortress.target` (ADR-035), never
      # multi-user.target — hang off the target it actually starts.
      wantedBy = ["fortress.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = createScript;
      };
      path = [pkgs.coreutils];
    };
  };
}
