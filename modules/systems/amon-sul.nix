{inputs, ...}: {
  flake.nixosConfigurations.amon-sul = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      inputs.self.modules.nixos.minimalBase
      inputs.self.modules.nixos.mediaServer
      inputs.vpn-confinement.nixosModules.default
      ../../hardware/amon-sul.nix
      ({pkgs, ...}: {
        networking.hostName = "amon-sul";

        networking.interfaces.enp11s0.useDHCP = false;
        networking.interfaces.enp11s0.ipv4.addresses = [
          {
            address = "192.168.0.7";
            prefixLength = 24;
          }
        ];
        networking.defaultGateway = "192.168.0.1";
        networking.nameservers = ["8.8.8.8" "1.1.1.1"];

        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;

        i18n.defaultLocale = "en_US.UTF-8";
        i18n.extraLocaleSettings = {
          LC_ADDRESS = "en_US.UTF-8";
          LC_IDENTIFICATION = "en_US.UTF-8";
          LC_MEASUREMENT = "en_US.UTF-8";
          LC_MONETARY = "en_US.UTF-8";
          LC_NAME = "en_US.UTF-8";
          LC_NUMERIC = "en_US.UTF-8";
          LC_PAPER = "en_US.UTF-8";
          LC_TELEPHONE = "en_US.UTF-8";
          LC_TIME = "en_US.UTF-8";
        };

        users.groups.brad = {};
        users.users.nicole = {
          isNormalUser = true;
          description = "Nicole";
          extraGroups = ["wheel" "jellyfin"];
          shell = pkgs.fish;
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBfMZjr6H4oK3qSBTxjZrMZptWXdzYC6QV4bdS892Ls nicole@vermissian"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1tyFv2UbkAJMx2U6bp8OwRx5wMpK7/DxSslcPS0sWY nicole@incarnadine"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDBQresTdgx3Se26QxvwD/S9SaCRCWL8dvZwZ6IM62b2 nicole@cheddar"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdPzSlJ3TCzPy7R2s2OOBJbBb+U5NY8dwMlGH9wm4Ot nicole@apiarist"
          ];
        };
        users.users.brad = {
          isNormalUser = true;
          description = "Brad";
          extraGroups = ["wheel" "jellyfin"];
          shell = pkgs.fish;
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHaOgK4fO5gTB79Infge2b+31VzXnC23lqV7m5NA+xuz bvenner@proton.me"
          ];
          group = "brad";
        };

        fileSystems."/backup" = {
          device = "/dev/disk/by-uuid/7b72c3a2-9a4b-4f43-b787-c179ec71847e";
          fsType = "btrfs";
          options = ["users" "nofail" "x-gvfs-show"];
        };

        fileSystems."/media" = {
          device = "/dev/disk/by-uuid/5424a16e-700b-4620-b7f9-713a1619eb88";
          fsType = "btrfs";
          options = ["users" "nofail" "x-gvfs-show"];
        };

        fileSystems."/export/media" = {
          device = "/media";
          fsType = "none";
          options = ["bind"];
        };

        services.nfs.server.exports = ''
          /media   192.168.0.0/16(rw,nohide,insecure,no_subtree_check)
        '';

        environment.variables.EDITOR = "nvim";
        environment.systemPackages = with pkgs; [
          zellij
          tmux
          neovim
          wget
          btop
          ripgrep-all
        ];

        system.stateVersion = "24.11";
      })
    ];
    specialArgs = {inherit inputs;};
  };
}
