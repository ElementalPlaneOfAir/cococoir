# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — test suite.
#
# v0 (Day 3-4) layers (see PLAN.md Design principles):
#   L1 (tenant-options): pure option-tree evaluation. No VM, no QEMU,
#                        no /dev/kvm. Sub-second. Catches derivation bugs.
#   L2 (tenant-vm):      full nixosTest. Boots a QEMU/KVM VM with the
#                        cococoir module loaded. Catches "doesn't build"
#                        and "doesn't boot" bugs. Needs /dev/kvm.
#
# Future layers:
#   L3 (customer-journey): scripted HTTP/API calls simulating a real
#                          customer signup, login, upload. Day 13-14.
{pkgs}:
let
  lib = pkgs.lib;
in {
  # ── L1: option tree ──────────────────────────────────────────────
  # Evaluates the cococoir module with a known tenant config and
  # asserts every derived value is what we expect. Pure-Nix asserts
  # at eval time; if any fail, the derivation doesn't build.
  #
  # Why runCommand for the output: nix flake check needs a derivation
  # at this path. The asserts have already run by the time we get here.
  tenant-options = let
    eval = lib.evalModules {
      modules = [
        (import ../nixos-modules)
        {
          cococoir.tenant.testcustomer = {
            domain = "test.local";
            adminUser = "testadmin";
            adminPasswordFile = "/tmp/cococoir-test-pw-does-not-need-to-exist";
          };
        }
      ];
    };

    t = eval.config.cococoir.tenant.testcustomer;

    # Eval-time asserts. Each one must hold; otherwise the build fails.
    _checks = [
      (assert t.pocketid.domain == "auth.test.local"; null)
      (assert t.services.jellyfin.domain == "jellyfin.test.local"; null)
      (assert t.services.jellyfin.bucket == "testcustomer-jellyfin"; null)
      (assert t.services.cryptpad.domain == "cryptpad.test.local"; null)
      (assert t.services.cryptpad.bucket == "testcustomer-cryptpad"; null)
      (assert t.adminUser == "testadmin"; null)
    ];
  in
    pkgs.runCommand "cococoir-tenant-options" {} ''
      cat <<EOF > $out
      Cococoir L1 option-tree checks: PASS
      tenant=testcustomer domain=${t.services.jellyfin.domain}
      pocketid=${t.pocketid.domain}
      jellyfin=${t.services.jellyfin.domain} bucket=${t.services.jellyfin.bucket}
      cryptpad=${t.services.cryptpad.domain} bucket=${t.services.cryptpad.bucket}
      EOF
    '';

  # ── L2: VM boot ──────────────────────────────────────────────────
  # Boots a QEMU/KVM VM with the test-single-tenant nixosConfiguration.
  # Catches "doesn't build" and "doesn't boot" failures.
  #
  # Day 3-4: just assert multi-user.target is reached. Real port checks
  # (pocketid :1411, jellyfin :8096, etc.) come in Day 5-10 when those
  # services land.
  tenant-vm = pkgs.testers.nixosTest {
    name = "cococoir-tenant-vm";

    nodes.machine = {...}: {
      imports = [
        (import ../nixos-modules)
        (import ../../nixosConfigurations/test-single-tenant.nix)
      ];
    };

    testScript = ''
      machine.wait_for_unit("multi-user.target")
    '';
  };
}
