# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress-apply package — the ADR-035 applier (see ./apply.sh). Built for the
# *target* host's pkgs; its runtime inputs are the tools the applier shells
# out to (nix to build the closure, systemctl to apply it, jq to read the
# closure's etc manifest).
{
  pkgs,
  ...
}:
pkgs.writeShellApplication {
  name = "fortress-apply";
  runtimeInputs = [
    pkgs.nix
    pkgs.systemd
    pkgs.coreutils
  ];
  text = builtins.readFile ./apply.sh;
}
