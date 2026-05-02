{ config, lib, ... }:
let
  cfg = config.cococoir.services.forgejo;
  domain = config.cococoir.domain;
in
{
  options.cococoir.services.forgejo = {
    enable = lib.mkEnableOption "Forgejo Git server";

    domain = lib.mkOption {
      type = lib.types.str;
      default = if domain != null then "git.${domain}" else "git.local";
      description = "Public domain for Forgejo.";
    };

    globallyAccessible = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose Forgejo on the public domain via Caddy.";
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

    services.caddy.virtualHosts = lib.mkMerge [
      {
        "http://git.${config.networking.hostName}.internal".extraConfig = ''
          reverse_proxy localhost:3000
        '';
      }
      (lib.mkIf cfg.globallyAccessible {
        "${cfg.domain}".extraConfig = ''
          reverse_proxy localhost:3000
        '';
      })
    ];
  };
}
