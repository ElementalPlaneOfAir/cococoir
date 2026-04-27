{
  pkgs,
  lib,
  config,
  ...
}: {
  imports = [ ./disk-config.nix ];

  networking.hostName = "ionos-vps";

  # Bootloader configured automatically by disko

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
    allowedUDPPorts = [443];
  };

  # Rathole server — forwards public 80/443 through the encrypted tunnel
  # to the client (amon-sul) where Caddy terminates TLS.
  services.rathole = {
    enable = true;
    role = "server";
    settings = {
      server = {
        bind_addr = "0.0.0.0:2333";
      };
      server.services.http = {
        bind_addr = "0.0.0.0:80";
      };
      server.services.https = {
        bind_addr = "0.0.0.0:443";
      };
      server.services.https_udp = {
        bind_addr = "0.0.0.0:443";
        type = "udp";
      };
    };
    credentialsFile = config.clan.core.vars.generators.rathole-tokens.files.server-tokens.path;
  };

  time.timeZone = "America/Denver";

  nix = {
    settings.trusted-users = ["root"];
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  environment.systemPackages = with pkgs; [
    git
    htop
    btop
  ];

  # Clan deployment target
  # TODO: Replace with your VPS public IP or hostname
  clan.core.networking.targetHost = "root@66.179.138.70";

  system.stateVersion = "24.11";
}
