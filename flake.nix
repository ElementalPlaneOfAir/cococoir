# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Cococoir v2: NixOS + btrfs + services for the home-server product. AGPL-3.0-or-later.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
    sops-nix.url = "github:Mic92/sops-nix";
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
      specialArgs = { inherit inputs; };
      modules = [
        ./nixosConfigurations/vmtest.nix
        "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        inputs.jellarr.nixosModules.default
      ];
    };

    nixosModulesWithJellarr = {
      imports = [
        inputs.jellarr.nixosModules.default
        ./nix/nixos-modules
      ];
    };

    # Dashboard dev environment. Not a bootable machine — a minimal
    # evaluation that renders only the Dex config for
    # `apps.dashboard-dev`, which runs Dex next to a bacon-watched
    # dashboard for the live-edit loop. See
    # nixosConfigurations/dashboard-dev.nix.
    dashboardDev = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./nixosConfigurations/dashboard-dev.nix
      ];
    };
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake.nixosModules.default = nixosModulesWithJellarr;
      flake.dashboardDev = dashboardDev;

      # Manual v2 dev VM: every cococoir service under test, each
      # behind its own Caddy vhost in the `vmtest.local`
      # cookie-jar. Today that includes Jellyfin and Dex;
      # nextcloud, gitea, etc. land here as the service modules
      # come online. Run with:
      #   nix run .#vmtest
      #   # or headless: nix run .#vmtest -- -nographic
      # See nixosConfigurations/vmtest.nix for full docs.
      flake.nixosConfigurations.vmtest = vmtest;

      perSystem = {pkgs, self', system, ...}: let
        # Dev Dex config: generated from the module system's own
        # services.dex.settings with the same pkgs.formats.yaml the
        # nixpkgs module uses, so the dev and VM renders can't drift.
        # Uses the nixosSystem's pkgs (not flake-parts' perSystem pkgs,
        # which come from a vendored nixpkgs fork — its `dex` is the
        # DesktopEntry launcher, not the OIDC provider).
        dexPkgs = dashboardDev._module.args.pkgs;
        dexBinary = "${dexPkgs.dex-oidc}/bin/dex";
        devDexConfig = (dexPkgs.formats.yaml { }).generate "dex.yaml"
          dashboardDev.config.services.dex.settings;
      in {
        checks = import ./nix/tests {
          inherit pkgs;
          sopsModule = inputs.sops-nix.nixosModules.sops;
        }
        # vmtest is pinned to x86_64-linux; only wire its eval
        # tripwire into checks on that system.
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") (
          import ./nix/tests/vmtest-wiring {
            inherit pkgs;
            vmtestConfig = vmtest.config;
          }
        );
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
        # Dashboard live-edit loop, managed by process-compose: dex
        # (readiness-gated) + bacon's dashboard job, torn down together
        # on Ctrl-C. Run from the repo root:
        #   nix run .#dashboard-dev
        # The pc spec lives in nix/dev/process-compose.nix — dev
        # tooling, deliberately outside the nixos modules.
        apps.dashboard-dev = let
          devPcConfig = (dexPkgs.formats.yaml {}).generate "dashboard-dev.yaml"
            (import ./nix/dev/process-compose.nix {
              inherit dexPkgs dexBinary devDexConfig;
            });
        in {
          type = "app";
          program = toString (dexPkgs.writeShellScript "dashboard-dev" ''
            exec ${dexPkgs.process-compose}/bin/process-compose -f ${devPcConfig}
          '');
        };
      };
    };
}
