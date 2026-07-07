# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Cococoir v2: multi-tenant self-hosting for the worker cooperative. AGPL-3.0-or-later.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
  };

  outputs = inputs:
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

      perSystem = {pkgs, system, ...}: {
        checks.${system} = (import ./nix/tests {inherit pkgs;}).placeholder;
      };
    };
}
