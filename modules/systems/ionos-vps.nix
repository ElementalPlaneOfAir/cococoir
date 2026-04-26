{inputs, ...}: {
  flake.nixosConfigurations.ionos-vps = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ({pkgs, lib, ...}: {
        networking.hostName = "ionos-vps";

        # Bootloader — verify the correct device after installing with nixos-infect.
        # Common values: /dev/sda, /dev/vda, /dev/nvme0n1
        boot.loader.grub.enable = true;
        boot.loader.grub.device = lib.mkDefault "/dev/sda";
        boot.loader.grub.useOSProber = false;

        # Placeholder root filesystem — override with your actual hardware config.
        fileSystems."/" = lib.mkDefault {
          device = "/dev/sda1";
          fsType = "ext4";
        };

        # Basic networking — DHCP is usually correct for VPSes.
        networking.useDHCP = true;

        # SSH access only via key auth
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "prohibit-password";
          };
        };

        users.users.root.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdPzSlJ3TCzPy7R2s2OOBJbBb+U5NY8dwMlGH9wm4Ot nicole@apiarist"
        ];

        # Firewall: 22 (SSH), 80 (HTTP), 443 (HTTPS), 2333 (rathole control)
        networking.firewall = {
          enable = true;
          allowedTCPPorts = [22 80 443 2333];
        };

        # Rathole server — forwards public 80/443 through the encrypted tunnel
        # to the client (amon-sul) where Caddy terminates TLS.
        services.rathole = {
          enable = true;
          role = "server";
          settings = {
            server = {
              bind_addr = "0.0.0.0:2333";
              transport.type = "noise";
            };
            server.services.http = {
              bind_addr = "0.0.0.0:80";
            };
            server.services.https = {
              bind_addr = "0.0.0.0:443";
            };
          };
          credentialsFile = "/etc/nixos/secrets/rathole-credentials.toml";
        };

        time.timeZone = "America/Denver";

        nix = {
          settings.trusted-users = ["root"];
          extraOptions = ''
            experimental-features = nix-command flakes
          '';
        };

        environment.systemPackages = with pkgs; [
          neovim
          git
          htop
          btop
        ];

        system.stateVersion = "24.11";
      })
    ];
    specialArgs = {inherit inputs;};
  };
}
