{
  description = "Self-hosting made simple: declarative home server proxy library";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      pkgsFor = system: import nixpkgs {
        inherit system;
      };
    in
    {
      nixosModules.default = { config, lib, pkgs, ... }: {
        imports = [
          ./modules/core.nix
          ./modules/base.nix
          ./modules/proxy/client.nix
          ./modules/proxy/server.nix
          ./modules/networking/caddy.nix
          ./modules/services/jellyfin.nix
          ./modules/services/vaultwarden.nix
          ./modules/services/forgejo.nix
          ./modules/services/matrix.nix
          ./modules/services/mautrix-gmessages.nix
          ./modules/services/cryptpad.nix
          ./modules/services/media-stack.nix
          ./modules/services/kavita.nix
          ./modules/services/custom.nix
        ];
      };

      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.buildGoModule {
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
        });

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              opentofu
              go
              gopls
              golangci-lint
            ];
          };
        });
    };
}
