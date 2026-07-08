# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — test machine: single tenant.
#
# v0 (Day 3-4) verification config. Used by:
#   - nix flake check                  (the L2 nixosTest boots this)
#   - nix build .#nixosConfigurations.test-single-tenant.config.system.build.vm
#                                     (the manual VM loop for dev iteration)
#   - nix eval .#nixosConfigurations.test-single-tenant.config.cococoir
#                                     (the L1 option tree checks)
#
# Manual loop:
#   nix build .#nixosConfigurations.test-single-tenant.config.system.build.vm
#   ./result/bin/run-test-single-tenant-vm
#   # in another terminal:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       root@localhost
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    (import ../nix/nixos-modules)
  ];

  cococoir.tenant.testcustomer = {
    domain = "test.local";
    adminUser = "testadmin";
    adminPasswordFile = ./fixtures/admin-password;
  };

  system.stateVersion = "25.11";
  networking.hostName = "test-single-tenant";
  networking.useDHCP = true;

  # Real NixOS VM config. Grub on /dev/vda, ext4 root. Works for both
  # `system.build.vm` (the manual loop) and nixosTest (the test driver
  # builds a disk image and boots it).
  boot.loader.grub.enable = true;
  boot.loader.grub.devices = [ "/dev/vda" ];
  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
  };

  # Allow SSH in for the manual VM loop (nixosTest doesn't need this;
  # it injects its own SSH key. Real production would disable root SSH.)
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  users.users.root.password = "";
}
