{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  cfg = config.cococoir.services;
  qbtEnabled = (cfg ? qbittorrent) && cfg.qbittorrent.enable;
in {
  options.cococoir.services = {};

  config = lib.mkMerge [
    # Shared media stack infrastructure
    (lib.mkIf qbtEnabled {
      users.groups.jellyfin = {};
      users.users.jellyfin = {
        isSystemUser = true;
        description = "Jellyfin System User";
        extraGroups = ["render" "video"];
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

    # VPN namespace + Caddy vhost + firewall for qBittorrent
    (lib.optionalAttrs (options ? vpnNamespaces) (lib.mkIf qbtEnabled {
      vpnNamespaces.wg = {
        enable = true;
        wireguardConfigFile = cfg.qbittorrent.vpnConfigFile;
        accessibleFrom = ["127.0.0.1"];
        portMappings = [
          {
            from = cfg.qbittorrent.webuiPort;
            to = cfg.qbittorrent.webuiPort;
          }
        ];
        openVPNPorts = [
          {
            port = cfg.qbittorrent.peerPort;
            protocol = "both";
          }
        ];
      };

      systemd.services.qbittorrent.vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };

      networking.firewall = {
        allowedTCPPorts = [cfg.qbittorrent.peerPort];
        allowedUDPPorts = [cfg.qbittorrent.peerPort];
      };

      services.caddy.virtualHosts."${cfg.qbittorrent.domain}".extraConfig = config.lib.cococoir.withAuth (
        if cfg.qbittorrent.public
        then ''reverse_proxy 192.168.15.1:${toString cfg.qbittorrent.webuiPort}''
        else ''
          @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
          respond @not_local "Forbidden" 403
          reverse_proxy 192.168.15.1:${toString cfg.qbittorrent.webuiPort}
        ''
      );
    }))
  ];
}
