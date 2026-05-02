{ lib, config, ... }:
let
  cfg = config.cococoir.proxy.client;
in
{
  options.cococoir.proxy.client = {
    enable = lib.mkEnableOption "rathole tunnel client (forwards local ports to a VPS)";

    serverAddress = lib.mkOption {
      type = lib.types.str;
      description = "Address of the rathole server (VPS public IP or hostname).";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 2333;
      description = "Port the rathole server control channel listens on.";
    };

    credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a TOML file containing rathole client service tokens.";
    };

    extraServices = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Extra rathole client services to forward. Merged into client.services.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.rathole = {
      enable = true;
      role = "client";
      settings = {
        client = {
          remote_addr = "${cfg.serverAddress}:${toString cfg.serverPort}";
        };
        client.services = {
          http = {
            local_addr = "127.0.0.1:80";
          };
          https = {
            local_addr = "127.0.0.1:443";
          };
          https_udp = {
            local_addr = "127.0.0.1:443";
            type = "udp";
          };
        } // cfg.extraServices;
      };
      inherit (cfg) credentialsFile;
    };
  };
}
