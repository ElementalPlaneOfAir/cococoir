{ config, lib, ... }:
let
  cfg = config.cococoir.services.autobrr;
in
{
  options.cococoir.services.autobrr = {
    enable = lib.mkEnableOption "autobrr release automation";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for the autobrr web interface.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to autobrr.";
    };

    secretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a file containing the autobrr session secret. Generate with `openssl rand -base64 32`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.autobrr = {
      enable = true;
      openFirewall = false;
      secretFile = cfg.secretFile;
      settings = {
        host = "127.0.0.1";
        port = 7474;
        logLevel = "INFO";
        sessionTimeout = 24 * 60 * 60;
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy 127.0.0.1:7474''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy 127.0.0.1:7474
      '';
  };
}
