# SPDX-License-Identifier: AGPL-3.0-or-later
{
  lib,
  config,
  ...
}: let
  cfg = config.tunnel.server;
in {
  options.tunnel.server = {
    enable = lib.mkEnableOption "rathole tunnel server (accepts public ports and forwards them to clients)";

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = ''
        Address to bind public-facing ports to.
        Use a specific IP if this VPS has multiple public IPs for different clients.
      '';
    };

    credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a TOML file containing rathole server service tokens.";
    };

    extraServices = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Extra rathole server services to accept. Merged into server.services.";
    };

    extraTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [];
      description = "Additional TCP ports to open in the firewall.";
    };

    extraUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [];
      description = "Additional UDP ports to open in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall = {
      allowedTCPPorts = [2333 80 443] ++ cfg.extraTCPPorts;
      allowedUDPPorts = [443] ++ cfg.extraUDPPorts;
    };

    services.rathole = {
      enable = true;
      role = "server";
      settings = {
        server = {
          bind_addr = "${cfg.bindAddress}:2333";
        };
        server.services =
          {
            http = {
              bind_addr = "${cfg.bindAddress}:80";
            };
            https = {
              bind_addr = "${cfg.bindAddress}:443";
            };
            https_udp = {
              bind_addr = "${cfg.bindAddress}:443";
              type = "udp";
            };
          }
          // cfg.extraServices;
      };
      inherit (cfg) credentialsFile;
    };
  };
}
