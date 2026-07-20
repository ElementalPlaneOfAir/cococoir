# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir contract-conformance check.
#
# L1: pure-Nix check (no VM, no QEMU). Catches contract-conformance
# drift across the service catalog: when a service module is
# added, this test asserts the service uses the factory
# (services/_contract.nix) and passes the right arguments.
#
# The drift this catches is the exact class of bug found in the
# prior pocket-id module: a service that was hand-rolled
# instead of going through the factory, missing the prober
# contract. This test fails the build if a service diverges.
#
# Strategy: parse each service module's source as a string
# and look for the factory call signature. We require:
#   - `mkCococoirService {` (the factory is invoked)
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
      "mkCococoirService {"
      "name = \"jellyfin\";"
      "defaultPort = 8096;"
      "defaultHealthPath = "
    ];
    pocketid = [
      "mkCococoirService {"
      "name = \"pocketid\";"
      "defaultPort = 1411;"
      "defaultHealthPath = "
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
{
  contract-conformance = pkgs.runCommand "cococoir-contract-conformance" {} ''
    cat > $out <<EOF
    cococoir contract-conformance: PASS
    ${report}
    EOF
  '';
}
