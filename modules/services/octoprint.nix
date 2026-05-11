{ config, lib, ... }:
let
  cfg = config.cococoir.services.octoprint;
in
{
  options.cococoir.services.octoprint = {
    enable = lib.mkEnableOption "OctoPrint 3D printer web interface";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for OctoPrint.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to OctoPrint.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.octoprint = {
      enable = true;
      host = "127.0.0.1";
      port = 5321;
      openFirewall = false;
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:5321''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:5321
      '';
  };
}
