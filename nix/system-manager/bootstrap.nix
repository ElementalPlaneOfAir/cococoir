# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress-bootstrap package — the first-run magic-folder generator (see
# ../../scripts/fortress-bootstrap.sh). Built for the *target* host's pkgs;
# runtimeInputs are the tools the generator shells out to. Providing them
# here means the script never needs its `nix shell` self-re-exec on NixOS, so
# first boot works offline — the re-exec remains for non-NixOS targets that
# carry neither the tools nor a package manager.
{
  pkgs,
  ...
}:
pkgs.writeShellApplication {
  name = "fortress-bootstrap";
  runtimeInputs = [
    pkgs.age
    pkgs.sops
    pkgs.git
    pkgs.openssl
    pkgs.mkpasswd
    pkgs.xkcdpass
    pkgs.util-linux
  ];
  text = builtins.readFile ../../scripts/fortress-bootstrap.sh;
}
