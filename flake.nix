# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Cococoir v2: NixOS + Garage + services for the home-server product. AGPL-3.0-or-later.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
    sops-nix.url = "github:Mic92/sops-nix";
    # Jellyfin plugins packaged as NixOS-installable derivations
    # (downloads the pre-built .dlls from the upstream GitHub
    # releases and exposes a `services.jellyfin.enabledPlugins`
    # option). Used for the SSO-Auth plugin that wires Jellyfin
    # to Pocket-ID. Maintained by LoCrealloc, not us.
    jellyfin-plugins-nix.url = "github:LoCrealloc/jellyfin-plugins-nix";
    # Declarative Jellyfin configuration (libraries, users,
    # plugin config, startup-wizard skip) via the official
    # Jellyfin REST API. The jellyfin service module activates
    # `services.jellarr` automatically when jellyfin is
    # enabled — customers never see jellarr as a separate
    # thing. Tracks main (no tag pin); the v0.1.0 tag fails
    # to evaluate on current nixpkgs.
    jellarr = {
      url = "github:venkyr77/jellarr";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let
    vmtest = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      # Pass the flake's inputs to the module so vmtest.nix can
      # reference `inputs.jellyfin-plugins-nix.packages.<sys>.<name>`.
      specialArgs = { inherit inputs; };
      modules = [
        ./nixosConfigurations/vmtest.nix
        # Modern nixpkgs (>= 25.05) only includes the QEMU VM module
        # in a `vmVariant` submodule, not the main config. Importing
        # it here declares options like `virtualisation.forwardPorts`
        # in the main config, which the vmtest config uses.
        "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        # LoCrealloc's jellyfin-plugins-nix module exposes
        # `services.jellyfin.enabledPlugins.<name>`. The SSO-Auth
        # plugin is enabled in vmtest.nix via that option.
        inputs.jellyfin-plugins-nix.nixosModules.jellyfin-plugins
        # Jellarr's NixOS module exposes `services.jellarr`
        # (enable, bootstrap, config, etc.). The cococoir
        # jellyfin service module activates it automatically
        # when `cococoir.services.jellyfin.enable = true`.
        inputs.jellarr.nixosModules.default
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

      # Manual v2 dev VM: every cococoir service under test, each
      # behind its own Caddy vhost in the `vmtest.local`
      # cookie-jar. Today that includes Jellyfin and Pocket-ID;
      # nextcloud, gitea, etc. land here as the service modules
      # come online. Run with:
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
