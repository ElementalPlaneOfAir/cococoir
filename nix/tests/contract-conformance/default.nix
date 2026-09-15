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
    qbittorrent = [
      "mkFortressService {"
      "name = \"qbittorrent\";"
      "defaultPort = 8080;"
      "defaultHealthPath = "
      "requires = [\"jellyfin\"];"
    ];
    seerr = [
      "mkFortressService {"
      "name = \"seerr\";"
      "defaultPort = 5055;"
      "defaultHealthPath = "
      "requires = [\"jellyfin\"];"
    ];
  };

  readService = name: builtins.readFile (../../nixos-modules/services + "/${name}.nix");

  # Storage-backend tripwire (storage/plain-dirs.nix, the container
  # tier). Service modules must derive paths from
  # fortress.storage.dataRoot and gate any
  # fortress-btrfs-subvolumes.service unit reference behind the
  # btrfsStorage gate. A hard-wired pool.mountpoint or an ungated
  # subvolume-unit reference renders fine on the customer (btrfs)
  # tier and breaks the container tier at boot — pure eval cannot
  # catch it, this source grep can.
  storageTripwire = name:
    let src = readService name; in
    assert lib.assertMsg (!(lib.hasInfix "btrfs.pool.mountpoint" src))
      "contract-conformance: ${name}.nix hard-wires fortress.storage.btrfs.pool.mountpoint — derive from fortress.storage.dataRoot instead (storage backend split)";
    assert lib.assertMsg (!(lib.hasInfix "fortress-btrfs-subvolumes" src) || lib.hasInfix "btrfsStorage" src)
      "contract-conformance: ${name}.nix references fortress-btrfs-subvolumes.service without the btrfsStorage gate — ungated, the reference kills the service on the plain-dirs (container) tier";
    "ok";

  check = name: needle:
    if lib.hasInfix needle (readService name) then "ok"
    else "MISSING: ${lib.escape ["\""] needle}";

  report = lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList (name: needles:
    map (n: "  ${name}: ${check name n}") needles
    ++ ["  ${name}: ${storageTripwire name}"]
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
