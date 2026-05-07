{ config, lib, ... }:
let
  cfg = config.cococoir.services.kavita;
in
{
  options.cococoir.services.kavita = {
    enable = lib.mkEnableOption "Kavita reading server";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Kavita.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Kavita.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.kavita = {
      enable = true;
      settings = {
        IpAddresses = "127.0.0.1";
        Port = 5000;
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:5000''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:5000
      '';
  };
}
