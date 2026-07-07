# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — test suite.
#
# v0 (Day 1-2): one placeholder nixosTest that boots a VM with the
# aggregator module imported, to prove the skeleton is wired correctly.
# More meaningful tests come in Day 3-4 (tenant module) and beyond.
{pkgs}: {
  placeholder = pkgs.testers.nixosTest {
    name = "cococoir-placeholder";

    nodes.machine = {...}: {
      imports = [
        ../nixos-modules
      ];
    };

    testScript = ''
      machine.wait_for_unit("multi-user.target")
    '';
  };
}
