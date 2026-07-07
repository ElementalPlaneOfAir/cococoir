# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/media-stack — shared infrastructure for the
# media stack: the jellyfin user (also used by qBittorrent, since
# qBittorrent runs as that user to share filesystem access to the
# FUSE-mounted Garage bucket) and the /media/entertain/* tmpfiles
# dirs (Jellyfin library roots + qBittorrent downloads).
#
# VPN namespace, Caddy vhost, and firewall for qBittorrent are also
# configured here — they depend on the qbittorrent options declared
# in modules/services/qbittorrent.nix.
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  cfg = config.cococoir.services;
  qbtEnabled = (cfg ? qbittorrent) && cfg.qbittorrent.enable;

  # Hardcoded to match nixpkgs services.qbittorrent defaults; these are
  # also hardcoded in modules/services/qbittorrent.nix.
  qbtWebuiPort = 8080;
  qbtPeerPort = 51413;
in {
  config = lib.mkMerge [
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

    (lib.optionalAttrs (options ? vpnNamespaces) (lib.mkIf qbtEnabled {
      vpnNamespaces.wg = {
        enable = true;
        wireguardConfigFile = cfg.qbittorrent.vpnConfigFile;
        accessibleFrom = ["127.0.0.1"];
        portMappings = [
          {
            from = qbtWebuiPort;
            to = qbtWebuiPort;
          }
        ];
        openVPNPorts = [
          {
            port = qbtPeerPort;
            protocol = "both";
          }
        ];
      };

      systemd.services.qbittorrent.vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };

      networking.firewall = {
        allowedTCPPorts = [qbtPeerPort];
        allowedUDPPorts = [qbtPeerPort];
      };

      services.caddy.virtualHosts."${cfg.qbittorrent.domain}".extraConfig = config.lib.cococoir.withAuth (
        if cfg.qbittorrent.public
        then ''reverse_proxy 192.168.15.1:${toString qbtWebuiPort}''
        else ''
          @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
          respond @not_local "Forbidden" 403
          reverse_proxy 192.168.15.1:${toString qbtWebuiPort}
        ''
      );
    }))
  ];
}
