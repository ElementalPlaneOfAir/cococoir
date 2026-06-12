{
  description = "Cococoir: declarative self-hosting for small office clusters. MIT-licensed.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/25.11.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
    vpn-confinement = {
      url = "github:Maroka-chan/VPN-Confinement";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem = { pkgs, system, ... }: {
        packages.default = pkgs.buildGoModule {
          pname = "cococoir";
          version = "0.1.0";
          src = ./cli;
          vendorHash = null;
          subPackages = [ "." ];
          ldflags = [
            "-s"
            "-w"
            "-X github.com/cococoir/cli/cmd.version=0.1.0"
          ];
          postInstall = ''
            mv $out/bin/cli $out/bin/cococoir
          '';
          meta = with pkgs.lib; {
            description = "CLI for managing Cococoir homelab deployments";
            license = licenses.mit;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            opentofu
            go
            gopls
            golangci-lint
          ];
        };
      };

      # ── NixOS modules exposed for consumption ──────────────────────────────
      # The full default is self-contained (does not reference flake
      # `inputs`), so it works in any module system. Consumers that want
      # clan-core, vpn-confinement, or other cococoir-bundled extras add
      # them as separate imports in their machine config. amon-sul does
      # this already; see machines/amon-sul in that repo for the pattern.
      flake.nixosModules.default = { ... }: {
        imports = [
          (inputs.import-tree ./modules)
        ];
      };

      # Per-module entry points for consumers who want a minimal surface.
      flake.nixosModules = {
        core = ./modules/core.nix;
        auth = ./modules/auth.nix;
        base = ./modules/base.nix;
        storage = ./modules/storage.nix;
        caddy = ./modules/networking/caddy.nix;
      };

      # Clan vars generators, auto-discovered from ./flake-vars/.
      # Each file there exposes flake.modules.nixos.<name> for one generator.
      # Consumers add a specific generator to their machine imports, e.g.:
      #   imports = [ inputs.cococoir.modules.nixos.storageVars ];
      #
      # Note: don't confuse this with ./vars/, which is clan's runtime
      # secret-state directory (not module definitions).
      flake.modules.nixos = inputs.import-tree ./flake-vars;
    };
}
