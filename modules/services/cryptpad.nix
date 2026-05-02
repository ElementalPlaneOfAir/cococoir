{ config, lib, ... }:
let
  cfg = config.cococoir.services.cryptpad;
  domain = config.cococoir.domain;
in
{
  options.cococoir.services.cryptpad = {
    enable = lib.mkEnableOption "CryptPad collaborative office suite";

    domain = lib.mkOption {
      type = lib.types.str;
      default = if domain != null then "cryptpad.${domain}" else "cryptpad.local";
      description = "Public domain for CryptPad.";
    };

    globallyAccessible = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose CryptPad on the public domain via Caddy.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.cryptpad = {
      enable = true;
      settings = {
        httpPort = 9000;
        httpAddress = "127.0.0.1";
        httpUnsafeOrigin = "https://${cfg.domain}";
        httpSafeOrigin = "https://${cfg.domain}";
      };
    };

    services.caddy.virtualHosts = lib.mkMerge [
      {
        "http://cryptpad.${config.networking.hostName}.internal".extraConfig = ''
          reverse_proxy localhost:9000
        '';
      }
      (lib.mkIf cfg.globallyAccessible {
        "${cfg.domain}".extraConfig = ''
          reverse_proxy localhost:9000
        '';
      })
    ];
  };
}
