{ pkgs, lib, ... }: {
  programs.fish.enable = true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  time.timeZone = lib.mkDefault "America/Denver";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  nix = {
    settings.trusted-users = [ "root" ];
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;
}
