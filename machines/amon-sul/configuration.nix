{pkgs, config, ...}: {
  imports = [ ../../hardware/amon-sul.nix ];

  networking.hostName = "amon-sul";

  cococoir.publicDomain = "interdim.net";
  cococoir.vpsAddress = "66.179.138.70";

  networking.interfaces.enp11s0.useDHCP = false;
  networking.interfaces.enp11s0.ipv4.addresses = [
    {
      address = "192.168.0.7";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = {
    address = "192.168.0.1";
    interface = "enp11s0";
  };
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

  users.users.nicole.extraGroups = ["jellyfin"];
  users.users.brad.extraGroups = ["jellyfin"];

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
    wget
    btop
    ripgrep-all
  ];

  # Clan deployment target
  clan.core.networking.targetHost = "root@192.168.0.7";

  system.stateVersion = "24.11";
}
