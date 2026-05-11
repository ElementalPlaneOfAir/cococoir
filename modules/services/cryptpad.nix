{ config, lib, ... }:
let
  cfg = config.cococoir.services.cryptpad;
in
{
  options.cococoir.services.cryptpad = {
    enable = lib.mkEnableOption "CryptPad collaborative office suite";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for CryptPad.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to CryptPad.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.cryptpad = {
      enable = true;
      settings = {
        httpPort = 9123;
        httpAddress = "127.0.0.1";
        httpUnsafeOrigin = "https://${cfg.domain}";
        httpSafeOrigin = "https://${cfg.domain}";
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:9123''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:9123
      '';
  };
}
