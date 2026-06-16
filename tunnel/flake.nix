# SPDX-License-Identifier: AGPL-3.0-or-later
#
# tunnel — separate-flake project for the VPS + rathole + sops stack
# that fronts a cococoir deployment. See ./README.md.
#
# Inputs: nixpkgs only. No clan-core, no vpn-confinement. This is a
# deliberately small lockfile.
{
  description = "tunnel: VPS provisioning (OpenTofu) + rathole tunnel (NixOS) + sops age keys. AGPL-3.0-or-later.";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in {
      nixosModules.client = ./nix/client.nix;
      nixosModules.server = ./nix/server.nix;

      devShells = nixpkgs.lib.genAttrs systems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            opentofu
            jq
          ];
        };
      });
    };
}
