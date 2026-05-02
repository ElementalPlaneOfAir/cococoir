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
      default = if domain != null then "matrix.${domain}" else "matrix.local";
      description = "Public domain for the Matrix server.";
    };

    globallyAccessible = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose Matrix on the public domain via Caddy.";
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

    services.caddy.virtualHosts = lib.mkMerge [
      {
        "http://matrix.${config.networking.hostName}.internal".extraConfig = ''
          reverse_proxy localhost:6167
        '';
      }
      (lib.mkIf cfg.globallyAccessible {
        "${cfg.domain}".extraConfig = ''
          reverse_proxy localhost:6167
        '';
        "${if domain != null then domain else config.networking.hostName}" = {
          extraConfig = ''
            handle_path /.well-known/matrix/server {
              header Content-Type application/json
              respond "{\"m.server\": \"matrix.${if domain != null then domain else config.networking.hostName}:443\"}"
            }
            handle_path /.well-known/matrix/client {
              header Content-Type application/json
              respond "{\"m.homeserver\": {\"base_url\": \"https://matrix.${if domain != null then domain else config.networking.hostName}\"}}"
            }
            redir https://jellyfin.${if domain != null then domain else config.networking.hostName}{uri} permanent
          '';
        };
      })
    ];
  };
}
