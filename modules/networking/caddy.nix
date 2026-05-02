{ lib, config, ... }: {
  services.caddy = {
    enable = lib.mkDefault true;
  };
}
