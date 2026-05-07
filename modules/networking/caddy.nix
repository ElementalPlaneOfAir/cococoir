{ lib, config, ... }: {
  services.caddy = {
    enable = lib.mkDefault true;
  };

  # HTTP/3 (QUIC) requires UDP 443 in addition to TCP 443
  networking.firewall = lib.mkIf config.services.caddy.enable {
    allowedUDPPorts = [ 443 ];
  };
}
