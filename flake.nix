{
  description = "Self-hosting made simple: declarative home server proxy library";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
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
  };
}
