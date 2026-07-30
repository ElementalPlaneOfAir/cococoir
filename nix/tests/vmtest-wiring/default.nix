# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir vmtest-wiring check.
#
# L1: pure option-tree evaluation against the *actual* vmtest
# nixosConfiguration. No VM, no QEMU. Catches the regression
# class where the OIDC integration silently vanishes from the
# rendered jellarr config — e.g. a lib.mkForce on
# services.jellarr.config discarding the integration's
# definitions, or the jellarr unit losing its boot activation.
#
# Why evaluate vmtest instead of a synthetic config: the bug
# this guards against lived in the composition of vmtest.nix
# with the cococoir modules, not in any single module. Only
# the real composition is a faithful tripwire.
{pkgs, vmtestConfig}:
let
  lib = pkgs.lib;
  jellarrCfg = vmtestConfig.services.jellarr;
  plugins = jellarrCfg.config.plugins or null;
  branding = jellarrCfg.config.branding or null;
  folderNames = map (f: f.name) jellarrCfg.config.library.virtualFolders;
in
assert lib.assertMsg (jellarrCfg.enable)
  "vmtest-wiring: services.jellarr is not enabled — the jellyfin service module must activate it";
assert lib.assertMsg (plugins != null)
  "vmtest-wiring: services.jellarr.config.plugins is null — the jellyfin-oidc integration was dropped (lib.mkForce on services.jellarr.config?)";
assert lib.assertMsg (branding != null)
  "vmtest-wiring: services.jellarr.config.branding is null — the jellyfin-oidc login button was dropped";
assert lib.assertMsg (builtins.elem "Movies" folderNames)
  "vmtest-wiring: vmtest's virtualFolders override did not apply";
assert lib.assertMsg (!(builtins.elem "Entertainment" folderNames))
  "vmtest-wiring: the jellyfin module's mkDefault virtualFolders leaked into vmtest (should be overridden)";
assert lib.assertMsg (builtins.elem "multi-user.target" vmtestConfig.systemd.services.jellarr.wantedBy)
  "vmtest-wiring: jellarr.service has no boot activation — declarative config would never apply on first boot";
{
  vmtest-wiring = pkgs.runCommand "cococoir-vmtest-wiring" {} ''
    cat > $out <<EOF
    cococoir vmtest-wiring: PASS
      jellarr enabled: yes
      OIDC plugins config present: yes
      branding (login button) present: yes
      virtualFolders: ${lib.concatStringsSep ", " folderNames}
      boot activation: multi-user.target
    EOF
  '';
}
