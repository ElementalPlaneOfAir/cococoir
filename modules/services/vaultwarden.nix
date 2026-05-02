{ config, lib, ... }:
let
  cfg = config.cococoir.services.vaultwarden;
  domain = config.cococoir.domain;
in
{
  options.cococoir.services.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden password manager";

    domain = lib.mkOption {
      type = lib.types.str;
      default = if domain != null then "vault.${domain}" else "vault.local";
      description = "Public domain for Vaultwarden.";
    };

    globallyAccessible = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose Vaultwarden on the public domain via Caddy.";
    };

    signupsAllowed = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to allow new signups.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;
      config = {
        DOMAIN = "https://${cfg.domain}";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        SIGNUPS_ALLOWED = cfg.signupsAllowed;
      };
    };

    services.caddy.virtualHosts = lib.mkMerge [
      {
        "http://vault.${config.networking.hostName}.internal".extraConfig = ''
          reverse_proxy localhost:8222
        '';
      }
      (lib.mkIf cfg.globallyAccessible {
        "${cfg.domain}".extraConfig = ''
          reverse_proxy localhost:8222
        '';
      })
    ];
  };
}
