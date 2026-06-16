{
  description = "Cococoir: declarative self-hosting for small office clusters. AGPL-3.0-or-later.";

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
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports =
        # Auto-import every clan-service module in ./clan-services/ by
        # picking up each subdir's `flake-module.nix`. The `default.nix`
        # files are the actual clan.service modules (class "clan.service"),
        # which cannot be imported as flake-parts modules — only their
        # `flake-module.nix` wrappers can.
        let
          dirContents = builtins.readDir ./clan-services;
          validModuleDirs = builtins.filter (
            name:
            name != "result"
            && dirContents.${name} == "directory"
            && builtins.pathExists (./clan-services + "/${name}/flake-module.nix")
          ) (builtins.attrNames dirContents);
        in
        map (name: ./clan-services + "/${name}/flake-module.nix") validModuleDirs;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem = {pkgs, ...}: {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            opentofu
            jq
          ];
        };
      };

      # ── NixOS modules exposed for consumption ──────────────────────────────
      # The full default is self-contained (does not reference flake
      # `inputs`), so it works in any module system. Consumers that want
      # clan-core, vpn-confinement, or other cococoir-bundled extras add
      # them as separate imports in their machine config. amon-sul does
      # this already; see machines/amon-sul in that repo for the pattern.
      flake.nixosModules.default = {...}: {
        imports = [
          (inputs.import-tree ./modules)
        ];
      };

      # Per-module entry points for consumers who want a minimal surface.
      flake.nixosModules = {
        core = ./modules/core.nix;
        auth = ./modules/auth.nix;
        base = ./modules/base.nix;
        caddy = ./modules/networking/caddy.nix;
      };

      # Clan vars generators are auto-imported via the `imports = [ ... ]`
      # at the top of this flake-parts block. Each file in ./flake-vars/
      # declares `flake.modules.nixos.<name>` and becomes an individually-
      # accessible entry in inputs.cococoir.modules.nixos.<name>.
      #
      # Note: don't confuse this with ./vars/, which is clan's runtime
      # secret-state directory (not module definitions).
    };
}
