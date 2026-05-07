{ config, lib, ... }:
let
  cfg = config.cococoir.services.matrix;
  domain = config.cococoir.domain;
in
{
  options.cococoir.services.matrix = {
    enable = lib.mkEnableOption "Matrix homeserver (continuwuity)";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for the Matrix server.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Matrix.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.matrix-continuwuity = {
      enable = true;
      settings = {
        global = {
          server_name = if domain != null then domain else config.networking.hostName;
          address = [ "127.0.0.1" ];
          port = [ 6167 ];
        };
      };
    };

    services.caddy.virtualHosts = {
      "${cfg.domain}".extraConfig =
        if cfg.public
        then ''reverse_proxy localhost:6167''
        else ''
          @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
          respond @not_local "Forbidden" 403
          reverse_proxy localhost:6167
        '';
    } // lib.optionalAttrs cfg.public {
      "${if domain != null then domain else config.networking.hostName}".extraConfig = ''
        handle_path /.well-known/matrix/server {
          header Content-Type application/json
          respond "{\"m.server\": \"matrix.${if domain != null then domain else config.networking.hostName}:443\"}"
        }
        handle_path /.well-known/matrix/client {
          header Content-Type application/json
          respond "{\"m.homeserver\": {\"base_url\": \"https://matrix.${if domain != null then domain else config.networking.hostName}\"}}"
        }
        redir https://${cfg.domain}{uri} permanent
      '';
    };
  };
}
