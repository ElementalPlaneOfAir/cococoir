# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/qbittorrent — qBittorrent BitTorrent client, with
# downloads landing on a FUSE-mounted Garage bucket.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable         — opt-in toggle
#   domain         — external FQDN for the Caddy vhost
#   public         — true → Caddy reverse-proxies; false → localNetworks 403
#   bucket         — name of the Garage bucket that backs the downloads
#
# qBittorrent-specific options (not in the standard 4-option contract):
#   vpnConfigFile  — required, WireGuard config for the namespace
#   peerPort       — incoming peer port (default 51413)
#   webuiPort      — WebUI listen port (default 8080)
#
# The download save path is derived from the FUSE mount: `<mountPoint>/downloads`.
# There is no `downloadDir` option — qBittorrent is a fully-S3-backed
# service in cococoir; non-S3 use cases should configure qBittorrent
# outside this module.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cococoir.services.qbittorrent;
  mount = config.cococoir.storage.derived.mounts.${cfg.bucket} or null;
  downloadDir = "${mount.mountPoint}/downloads";
in {
  options.cococoir.services.qbittorrent = {
    enable = lib.mkEnableOption "qBittorrent BitTorrent client";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External FQDN for the qBittorrent WebUI.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to qBittorrent.";
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the Garage bucket that backs the qBittorrent downloads.
        A FUSE mount for this bucket must be declared in the
        cococoir/garage clan-service's `mounts.<name>`.
      '';
    };

    vpnConfigFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the WireGuard configuration file for the VPN namespace.";
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
    assertions = [
      {
        assertion = mount != null;
        message = ''
          cococoir/services/qbittorrent: bucket "${cfg.bucket}" has no
          FUSE mount declared in the cococoir/garage clan-service. Add
          an entry to `roles.<role>.machines.<name>.settings.mounts`:
            mounts.<name> = {
              bucket = "${cfg.bucket}";
              mountPoint = "/media/entertain";
            };
        '';
      }
    ];

    services.qbittorrent = {
      enable = true;
      user = "jellyfin";
      group = "jellyfin";
      webuiPort = cfg.webuiPort;
      torrentingPort = cfg.peerPort;
      openFirewall = false;
      serverConfig.Preferences = {
        Downloads.SavePath = downloadDir;
        Connection.PortRangeMin = cfg.peerPort;
        WebUI.AuthSubnetWhitelist = "127.0.0.0/8";
        WebUI.AuthSubnetWhitelistEnabled = true;
        WebUI.HostHeaderValidationEnabled = false;
      };
    };
  };
}
