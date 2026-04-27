{
  description = "Homelab and VPS configuration";

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} (
      {self, ...}: let
        injectInputs = {...}: {
          _module.args.inputs = inputs;
        };
      in {
        imports = [
          inputs.clan-core.flakeModules.default
          (inputs.import-tree ./modules)
        ];

        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-darwin"
        ];

        perSystem = {pkgs, system, ...}: {
          devShells.default = pkgs.mkShell {
            packages = [inputs.clan-core.packages.${system}.clan-cli];
          };
        };

        clan = {
          meta.name = "cococoir";
          # TODO: Change this to your public domain (e.g. "example.com")
          # or an internal domain you control. Clan uses this for service
          # discovery, internal SSL certificates, and mesh networking.
          meta.domain = "cococoir.local";

          machines = {
            amon-sul = {
              nixpkgs.hostPlatform = "x86_64-linux";
              imports = [
                injectInputs
                inputs.vpn-confinement.nixosModules.default
                inputs.self.modules.nixos.minimalBase
                inputs.self.modules.nixos.mediaServer
                inputs.self.modules.nixos.ratholeVars
                inputs.self.modules.nixos.users
                ./machines/amon-sul/configuration.nix
              ];
            };

            ionos-vps = {
              nixpkgs.hostPlatform = "x86_64-linux";
              imports = [
                injectInputs
                inputs.self.modules.nixos.ratholeVars
                inputs.self.modules.nixos.users
                ./machines/ionos-vps/configuration.nix
              ];
            };
          };
        };
      }
    );

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    import-tree.url = "github:vic/import-tree";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/25.11.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.sops-nix.follows = "sops-nix";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    limonene = {
      url = "github:cappuccinocosmico/limonene";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vpn-confinement = {
      url = "github:Maroka-chan/VPN-Confinement";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
