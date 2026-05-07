{ config, lib, ... }:
let
  cfg = config.cococoir.services.forgejo;
in
{
  options.cococoir.services.forgejo = {
    enable = lib.mkEnableOption "Forgejo Git server";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Forgejo.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Forgejo.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.forgejo = {
      enable = true;
      settings = {
        server = {
          DOMAIN = cfg.domain;
          ROOT_URL = "https://${cfg.domain}";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = 3000;
        };
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:3000''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:3000
      '';
  };
}
