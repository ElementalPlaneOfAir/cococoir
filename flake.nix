# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Cococoir v2: multi-tenant self-hosting for the worker cooperative. AGPL-3.0-or-later.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs = inputs: let
    vmtest = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./nixosConfigurations/vmtest.nix
        # Modern nixpkgs (>= 25.05) only includes the QEMU VM module
        # in a `vmVariant` submodule, not the main config. Importing
        # it here declares options like `virtualisation.forwardPorts`
        # in the main config, which the vmtest config uses.
        "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      ];
    };
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake.nixosModules.default = {...}: {
        imports = [
          ./nix/nixos-modules
        ];
      };

      # Test machine configurations. The nixosConfiguration output is
      # what makes the manual VM loop work:
      #   nix build .#nixosConfigurations.test-single-tenant.config.system.build.vm
      #   ./result/bin/run-test-single-tenant-vm
      flake.nixosConfigurations.test-single-tenant = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./nixosConfigurations/test-single-tenant.nix
        ];
      };

      # Manual v2 dev VM: every cococoir service under test, each
      # behind its own Caddy vhost in the `cococoir-vmtest.local`
      # cookie-jar. Today that's Jellyfin; nextcloud/gitea/etc.
      # land here as the service modules come online. Run with:
      #   nix run .#vmtest
      #   # or headless: nix run .#vmtest -- -nographic
      # See nixosConfigurations/vmtest.nix for full docs.
      flake.nixosConfigurations.vmtest = vmtest;

      perSystem = {pkgs, self', ...}: {
        checks = import ./nix/tests {
          inherit pkgs;
          sopsModule = inputs.sops-nix.nixosModules.sops;
        };
        # The app's `program` field is just a string path. We avoid
        # interpolation of `vmtest.config.system.build.vm` (which
        # flake-parts mishandles) by shelling out to `nix run` on
        # the nixosConfiguration attribute path. The nix run
        # re-evaluates the config and dispatches the vm's run
        # script.
        apps.vmtest = {
          type = "app";
          program = toString (pkgs.writeShellScript "vmtest-run" ''
            exec nix run .#nixosConfigurations.vmtest.config.system.build.vm -- "$@"
          '');
        };
      };
    };
}
