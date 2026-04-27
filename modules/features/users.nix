{inputs, ...}: {
  imports = [inputs.flake-parts.flakeModules.modules];

  flake.modules.nixos.users = {
    pkgs,
    inputs,
    ...
  }: let
    nicole_ssh_keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBfMZjr6H4oK3qSBTxjZrMZptWXdzYC6QV4bdS892Ls nicole@vermissian"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1tyFv2UbkAJMx2U6bp8OwRx5wMpK7/DxSslcPS0sWY nicole@incarnadine"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDBQresTdgx3Se26QxvwD/S9SaCRCWL8dvZwZ6IM62b2 nicole@cheddar"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdPzSlJ3TCzPy7R2s2OOBJbBb+U5NY8dwMlGH9wm4Ot nicole@apiarist"
    ];
  in {
    programs.fish.enable = true;

    users.groups.brad = {};

    users.users.root = {
      openssh.authorizedKeys.keys = nicole_ssh_keys;
    };
    users.users.nicole = {
      isNormalUser = true;
      description = "Nicole";
      extraGroups = ["wheel"];
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = nicole_ssh_keys;
    };

    users.users.brad = {
      isNormalUser = true;
      description = "Brad";
      extraGroups = ["wheel"];
      shell = pkgs.fish;
      group = "brad";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHaOgK4fO5gTB79Infge2b+31VzXnC23lqV7m5NA+xuz bvenner@proton.me"
      ];
    };

    environment.systemPackages = [
      inputs.limonene.packages.${pkgs.system}.nvim
    ];
  };
}
