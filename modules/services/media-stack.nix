{ config, lib, pkgs, options, ... }:
let
  cfg = config.cococoir.services;

  mkServiceVhost = name: port: serviceCfg: {
    "${serviceCfg.domain}".extraConfig =
      if serviceCfg.public
      then ''reverse_proxy localhost:${toString port}''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:${toString port}
      '';
  };
in
{
  options.cococoir.services = {
    transmission = {
      enable = lib.mkEnableOption "Transmission BitTorrent client";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for Transmission.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to Transmission.";
      };

      vpnConfigFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the WireGuard configuration file for the VPN namespace.";
      };

      downloadDir = lib.mkOption {
        type = lib.types.path;
        default = "/media/entertain/downloads";
      };

      peerPort = lib.mkOption {
        type = lib.types.port;
        default = 51413;
      };
    };

    radarr = {
      enable = lib.mkEnableOption "Radarr movie management";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for Radarr.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to Radarr.";
      };
    };

    sonarr = {
      enable = lib.mkEnableOption "Sonarr TV show management";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for Sonarr.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to Sonarr.";
      };
    };

    lidarr = {
      enable = lib.mkEnableOption "Lidarr music management";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for Lidarr.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to Lidarr.";
      };
    };

    bazarr = {
      enable = lib.mkEnableOption "Bazarr subtitle management";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for Bazarr.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to Bazarr.";
      };
    };

    prowlarr = {
      enable = lib.mkEnableOption "Prowlarr indexer management";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for Prowlarr.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to Prowlarr.";
      };
    };

    flaresolverr = {
      enable = lib.mkEnableOption "FlareSolverr proxy";

      domain = lib.mkOption {
        type = lib.types.str;
        description = "External domain for FlareSolverr.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to allow public access to FlareSolverr.";
      };
    };
  };

  config = lib.mkMerge [
    # Shared media stack infrastructure
    (lib.mkIf (
      cfg.transmission.enable || cfg.radarr.enable || cfg.sonarr.enable
      || cfg.lidarr.enable || cfg.bazarr.enable || cfg.prowlarr.enable
      || cfg.flaresolverr.enable
    ) {
      users.groups.jellyfin = {};
      users.users.jellyfin = {
        isSystemUser = true;
        description = "Jellyfin System User";
        extraGroups = [ "render" "video" ];
      };

      systemd.tmpfiles.rules = [
        "d /media/entertain           0775 jellyfin jellyfin -"
        "d /media/entertain/books     0775 jellyfin jellyfin -"
        "d /media/entertain/downloads 0775 jellyfin jellyfin -"
        "d /media/entertain/dvr       0775 jellyfin jellyfin -"
        "d /media/entertain/games     0775 jellyfin jellyfin -"
        "d /media/entertain/movies    0775 jellyfin jellyfin -"
        "d /media/entertain/music     0775 jellyfin jellyfin -"
        "d /media/entertain/papers    0775 jellyfin jellyfin -"
        "d /media/entertain/shows     0775 jellyfin jellyfin -"
        "d /media/entertain/subtitles 0775 jellyfin jellyfin -"
      ];
    })

    # Transmission with VPN confinement
    (lib.mkIf cfg.transmission.enable {
      services.transmission = {
        enable = true;
        package = pkgs.transmission_4;
        openRPCPort = false;
        openPeerPorts = true;
        user = "jellyfin";
        group = "jellyfin";
        settings = {
          rpc-bind-address = "0.0.0.0";
          rpc-whitelist-enabled = false;
          peer-port = cfg.transmission.peerPort;
          download-dir = cfg.transmission.downloadDir;
        };
      };

      networking.firewall = {
        allowedTCPPorts = [ cfg.transmission.peerPort ];
        allowedUDPPorts = [ cfg.transmission.peerPort ];
      };

      services.caddy.virtualHosts."${cfg.transmission.domain}".extraConfig =
        if cfg.transmission.public
        then ''reverse_proxy 192.168.15.1:9091''
        else ''
          @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
          respond @not_local "Forbidden" 403
          reverse_proxy 192.168.15.1:9091
        '';
    })

    (lib.optionalAttrs (options ? vpnNamespaces) (lib.mkIf cfg.transmission.enable {
      vpnNamespaces.wg = {
        enable = true;
        wireguardConfigFile = cfg.transmission.vpnConfigFile;
        accessibleFrom = [ "127.0.0.1" ];
        portMappings = [
          { from = 9091; to = 9091; }
        ];
        openVPNPorts = [
          { port = cfg.transmission.peerPort; protocol = "both"; }
        ];
      };

      systemd.services.transmission.vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };
    }))

    # Radarr
    (lib.mkIf cfg.radarr.enable {
      services.radarr = {
        enable = true;
        openFirewall = false;
        user = "jellyfin";
        group = "jellyfin";
        settings.server.bindaddress = "127.0.0.1";
      };
      services.caddy.virtualHosts = mkServiceVhost "radarr" 7878 cfg.radarr;
    })

    # Sonarr
    (lib.mkIf cfg.sonarr.enable {
      services.sonarr = {
        enable = true;
        openFirewall = false;
        user = "jellyfin";
        group = "jellyfin";
        settings.server.bindaddress = "127.0.0.1";
      };
      services.caddy.virtualHosts = mkServiceVhost "sonarr" 8989 cfg.sonarr;
    })

    # Lidarr
    (lib.mkIf cfg.lidarr.enable {
      services.lidarr = {
        enable = true;
        openFirewall = false;
        user = "jellyfin";
        group = "jellyfin";
        settings.server.bindaddress = "127.0.0.1";
      };
      services.caddy.virtualHosts = mkServiceVhost "lidarr" 8686 cfg.lidarr;
    })

    # Bazarr
    (lib.mkIf cfg.bazarr.enable {
      services.bazarr = {
        enable = true;
        openFirewall = false;
        user = "jellyfin";
        group = "jellyfin";
      };
      services.caddy.virtualHosts = mkServiceVhost "bazarr" 6767 cfg.bazarr;
    })

    # Prowlarr
    (lib.mkIf cfg.prowlarr.enable {
      services.prowlarr = {
        enable = true;
        openFirewall = false;
        settings.server.bindaddress = "127.0.0.1";
      };
      services.caddy.virtualHosts = mkServiceVhost "prowlarr" 9696 cfg.prowlarr;
    })

    # FlareSolverr
    (lib.mkIf cfg.flaresolverr.enable {
      services.flaresolverr = {
        enable = true;
        openFirewall = false;
      };
      services.caddy.virtualHosts = mkServiceVhost "flaresolverr" 8191 cfg.flaresolverr;
    })
  ];
}
