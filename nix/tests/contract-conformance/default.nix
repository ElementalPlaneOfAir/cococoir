# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress contract-conformance check.
#
# L1: pure-Nix check (no VM, no QEMU). Catches contract-conformance
# drift across the service catalog: when a service module is
# added, this test asserts the service uses the factory
# (services/_contract.nix) and passes the right arguments.
#
# The drift this catches is the exact class of bug where a service
# module diverges from the factory contract — different option
# surface, missing health path, missing port declaration, etc.
# This check fails the build if a service diverges.
#
# Strategy: parse each service module's source as a string
# and look for the factory call signature. We require:
#   - `mkFortressService {` (the factory is invoked)
#   - `name = "<service>";` (factory receives the right name)
#   - `defaultPort = <number>;` (port contract honored)
#   - `defaultHealthPath = "...";` (prober contract honored)
# Adding a new service: add the service name to `expected`
# below.
{pkgs}:
let
  lib = pkgs.lib;

  # The known services and the substrings that MUST appear
  # in each service's source file. Adding a new service: add
  # a row here.
  expected = {
    jellyfin = [
      "mkFortressService {"
      "name = \"jellyfin\";"
      "defaultPort = 8096;"
      "defaultHealthPath = "
    ];
    dex = [
      "mkFortressService {"
      "name = \"dex\";"
      "defaultPort = 5556;"
      "defaultHealthPath = "
    ];
    cryptpad = [
      "mkFortressService {"
      "name = \"cryptpad\";"
      "defaultPort = 3000;"
      "defaultHealthPath = "
    ];
    radarr = [
      "mkFortressService {"
      "name = \"radarr\";"
      "defaultPort = 7878;"
      "defaultHealthPath = "
      "requires = [\"jellyfin\"];"
    ];
    sonarr = [
      "mkFortressService {"
      "name = \"sonarr\";"
      "defaultPort = 8989;"
      "defaultHealthPath = "
      "requires = [\"jellyfin\"];"
    ];
    lidarr = [
      "mkFortressService {"
      "name = \"lidarr\";"
      "defaultPort = 8686;"
      "defaultHealthPath = "
      "requires = [\"jellyfin\"];"
    ];
    prowlarr = [
      "mkFortressService {"
      "name = \"prowlarr\";"
      "defaultPort = 9696;"
      "defaultHealthPath = "
      "requires = [\"jellyfin\"];"
    ];
  };

  readService = name: builtins.readFile (../../nixos-modules/services + "/${name}.nix");

  check = name: needle:
    if lib.hasInfix needle (readService name) then "ok"
    else "MISSING: ${lib.escape ["\""] needle}";

  report = lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList (name: needles:
    map (n: "  ${name}: ${check name n}") needles
  ) expected));
in
assert lib.assertMsg (!(lib.hasInfix "MISSING" report))
  "contract-conformance failed:\n${report}";
{
  contract-conformance = pkgs.runCommand "fortress-contract-conformance" {} ''
    cat > $out <<EOF
    fortress contract-conformance: PASS
    ${report}
    EOF
  '';
}
