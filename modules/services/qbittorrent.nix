{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cococoir.services.qbittorrent;
in {
  options.cococoir.services.qbittorrent = {
    enable = lib.mkEnableOption "qBittorrent BitTorrent client";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for the qBittorrent WebUI.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to qBittorrent.";
    };

    vpnConfigFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the WireGuard configuration file for the VPN namespace.";
    };

    downloadDir = lib.mkOption {
      type = lib.types.path;
      default = "/media/entertain/downloads";
      description = "Directory where completed downloads are stored.";
    };

    peerPort = lib.mkOption {
      type = lib.types.port;
      default = 51413;
      description = "Port used for incoming peer connections.";
    };

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the qBittorrent WebUI listens on (inside the VPN namespace).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.qbittorrent = {
      enable = true;
      user = "jellyfin";
      group = "jellyfin";
      webuiPort = cfg.webuiPort;
      torrentingPort = cfg.peerPort;
      openFirewall = false;
      serverConfig.Preferences = {
        Downloads.SavePath = cfg.downloadDir;
        Connection.PortRangeMin = cfg.peerPort;
        WebUI.AuthSubnetWhitelist = "127.0.0.0/8";
        WebUI.AuthSubnetWhitelistEnabled = true;
        WebUI.HostHeaderValidationEnabled = false;
      };
    };
  };
}
