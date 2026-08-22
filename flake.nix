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
    # Manage the edge box on a stock Debian image: systemd services,
    # packages, and root-level config applied atomically with Nix,
    # without taking over the OS. The edge never needed full NixOS
    # (it's a stateless forwarder), and a stock image removes the
    # disko/fstab/NIC boot problems entirely. Customer boxes stay NixOS.
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Rust build library: splits `buildDepsOnly` (workspace deps, built
    # once + cached) from `buildPackage` (our crate, recompiled on
    # change) so a source edit doesn't rebuild every dependency.
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let
    # nixpkgs with the crane flake injected as an attribute, so any
    # `pkgs.callPackage ./packages/cococoir {}` (in the NixOS
    # modules, the tests, the edge systemConfig) resolves the `crane`
    # arg it now needs, without threading the flake input through every
    # call site.
    withCrane = system: (import inputs.nixpkgs { inherit system; }).extend (final: prev: {
      crane = inputs.crane;
    });
    vmtestPkgs = withCrane "x86_64-linux";
    vmtest = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      pkgs = vmtestPkgs;
      specialArgs = { inherit inputs; };
      modules = [
        ./nixosConfigurations/vmtest.nix
        "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        inputs.jellarr.nixosModules.default
      ];
    };

    # Customer box (home machine, full v2 stack). Rendered by
    # remote-infra/tofu from templates/example123.nix.tftpl — do not
    # hand-edit. Needs jellarr for jellyfin declarative config + OIDC.
    example123 = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      pkgs = withCrane "x86_64-linux";
      modules = [
        ./remote-infra/nix/example123.nix
        inputs.jellarr.nixosModules.default
      ];
    };

    nixosModulesWithJellarr = {
      imports = [
        inputs.jellarr.nixosModules.default
        ./nix/nixos-modules
      ];
    };
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake.nixosModules.default = nixosModulesWithJellarr;

      # The edge box is managed by system-manager on a stock Debian
      # image (not NixOS). systemConfigs.edge is the system-manager
      # config; the merged cococoir-edge binary is injected via
      # extraSpecialArgs. Deploy with:
      #   nix run .#system-manager -- switch --flake .#edge
      flake.systemConfigs.edge = inputs.system-manager.lib.makeSystemConfig {
        modules = [./remote-infra/system-manager/edge.nix];
        specialArgs = {
          cococoirEdgePkg = inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/cococoir {
            crane = inputs.crane;
          };
        };
      };

      # Manual v2 dev VM: every cococoir service under test, each
      # behind its own Caddy vhost in the `vmtest.local`
      # cookie-jar. Today that includes Jellyfin and Dex;
      # nextcloud, gitea, etc. land here as the service modules
      # come online. Run with:
      #   nix run .#vmtest
      #   # or headless: nix run .#vmtest -- -nographic
      # See nixosConfigurations/vmtest.nix for full docs.
      flake.nixosConfigurations.vmtest = vmtest;
      flake.nixosConfigurations.example123 = example123;

      perSystem = {pkgs, self', system, ...}: let
        # Real nixpkgs for dev tooling. flake-parts' perSystem `pkgs`
        # come from a vendored nixpkgs fork (its `dex` is the
        # DesktopEntry launcher, not the OIDC provider), so service
        # binaries and config renders always come from here.
        realPkgs = inputs.nixpkgs.legacyPackages.${system};
        # Dev admin login for the dashboard: password = "password".
        # Generate a fresh one with `mkpasswd -m bcrypt -R 10 <pw>`.
        devAdminHash =
          "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W";
      in {
        checks = import ./nix/tests {
          inherit (withCrane system) pkgs;
          sopsModule = inputs.sops-nix.nixosModules.sops;
        }
        # vmtest is pinned to x86_64-linux; only wire its eval
        # tripwire into checks on that system.
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") (
          import ./nix/tests/vmtest-wiring {
            inherit (withCrane system) pkgs;
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
        # secretspec 0.19 CLI from the flake's locked nixpkgs. The
        # devshell's `secretspec` comes from devenv's own nixpkgs and is
        # an older version without the `file` provider backend, so the
        # provisioning scripts and this app are the pinned, canonical
        # entry point. Run from the repo root:
        #   nix run .#secretspec -- export -P provisioning -S token ...
        apps.secretspec = {
          type = "app";
          program = "${realPkgs.secretspec}/bin/secretspec";
        };
        # Dashboard live-edit loop, managed by process-compose: bacon's
        # dashboard job with the admin login enabled, torn down cleanly
        # on Ctrl-C. Run from the repo root:
        #   nix run .#dashboard-dev
        # The pc spec lives in nix/dev/process-compose.nix — dev
        # tooling, deliberately outside the nixos modules.
        apps.dashboard-dev = let
          devPcConfig = (realPkgs.formats.yaml {}).generate "dashboard-dev.yaml"
            (import ./nix/dev/process-compose.nix {
              pkgs = realPkgs;
              adminPasswordHash = devAdminHash;
            });
        in {
          type = "app";
          program = toString (realPkgs.writeShellScript "dashboard-dev" ''
            # TUI when attached to a terminal; -t=false keeps the
            # process tree managed the same way in headless runs.
            # --no-server: pc's web UI is unused and its 8080 binding
            # collides with anything else on that port.
            if [ -t 0 ]; then
              exec ${realPkgs.process-compose}/bin/process-compose --no-server -f ${devPcConfig}
            else
              exec ${realPkgs.process-compose}/bin/process-compose --no-server -t=false -f ${devPcConfig}
            fi
          '');
        };
      };
    };
}
