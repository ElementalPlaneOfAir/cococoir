# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress applier trampoline (ADR-035, boundary ADR-037).
#
# This is the ONLY fortress module a *machine* flake imports. It is NOT the
# service stack: that lives in `nixosModules.default`, and the applier builds
# it from the magic folder at run time, outside the OS closure. A machine
# importing the service stack would drag the fortress service closure into the
# `nixos-rebuild` closure, which is the coupling ADR-035 rejects. The machine
# owns hardware; the folder owns the app.
#
# What this installs: a boot-time oneshot that generates the magic folder when
# it is absent, then an oneshot that builds and applies its systemd units.
# The apply runs on EVERY boot because `fortress-apply` installs into
# /run/systemd/system, which is tmpfs and cleared on reboot — without this the
# box would come up with no fortress at all.
{config, lib, pkgs, ...}: let
  cfg = config.fortress.applier;
  fortressApply = import ../system-manager/apply.nix {inherit pkgs;};
  fortressBootstrap = import ../system-manager/bootstrap.nix {inherit pkgs;};
  root = "/etc/fortress";
in {
  options.fortress.applier.enable =
    lib.mkEnableOption "the fortress applier boot trampoline (ADR-035)";

  config = lib.mkIf cfg.enable {
    systemd.services.fortress-bootstrap = {
      description = "Generate the fortress magic folder on first boot";
      wantedBy = ["multi-user.target"];
      before = ["fortress-apply.service"];
      # Skip the generator entirely once a folder exists — bootstrap is
      # idempotent, but not running it at all keeps reboot off the crypto path
      # and makes the "first boot only" contract mechanical.
      unitConfig.ConditionPathExists = "!${root}/config/flake.nix";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${fortressBootstrap}/bin/fortress-bootstrap --root ${root}";
      };
    };

    systemd.services.fortress-apply = {
      description = "Apply the fortress magic folder to systemd (ADR-035)";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target" "fortress-bootstrap.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${fortressApply}/bin/fortress-apply ${root}/config";
      };
      # `rm flake.lock` is the documented re-pin flow, and nix shells out to
      # `git` to re-lock a git+file flake. Without it on PATH the apply dies
      # with `error: executing "git": No such file or directory` the moment
      # the lock file is absent.
      path = [pkgs.git pkgs.nix];
    };
  };
}
