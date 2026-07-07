# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/qbittorrent — qBittorrent BitTorrent client, with
# downloads landing on a FUSE-mounted Garage bucket.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable         — opt-in toggle
#   domain         — external FQDN for the Caddy vhost
#   public         — true → Caddy reverse-proxies; false → localNetworks 403
#   bucket         — name of the Garage bucket (default "media", same
#                    as jellyfin so a single bucket covers both)
#
# qBittorrent-specific option (not in the standard 4-option contract):
#   vpnConfigFile  — required, WireGuard config for the namespace
#
# The download save path is derived from the FUSE mount:
# `<mountPoint>/downloads`. The peer port (51413) and WebUI port
# (8080) match nixpkgs services.qbittorrent defaults and are
# repeated in media-stack.nix where the VPN namespace + Caddy vhost
# + firewall are configured. There is no `downloadDir` option —
# qBittorrent is a fully-S3-backed service in cococoir; non-S3 use
# cases should configure qBittorrent outside this module.
{
  config,
  lib,
  ...
}: let
  cfg = config.cococoir.services.qbittorrent;
  defaultBucket = "media";
  defaultMount = "/media/entertain";
  mount = config.cococoir.storage.derived.mounts.${cfg.bucket};
  downloadDir = "${mount.mountPoint}/downloads";
  webuiPort = 8080;
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
      default = defaultBucket;
      description = ''
        Name of the Garage bucket that backs the qBittorrent
        downloads. Defaults to "${defaultBucket}" (same as jellyfin,
        so both share a single bucket + mount).
      '';
    };

    vpnConfigFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the WireGuard configuration file for the VPN namespace.";
    };
  };

  config = lib.mkIf cfg.enable {
    cococoir.storage.buckets.${cfg.bucket} = { };
    cococoir.storage.mounts.${cfg.bucket} = {
      bucket = cfg.bucket;
      mountPoint = defaultMount;
    };

    services.qbittorrent = {
      enable = true;
      user = "jellyfin";
      group = "jellyfin";
      webuiPort = webuiPort;
      torrentingPort = 51413;
      openFirewall = false;
      serverConfig.Preferences = {
        Downloads.SavePath = downloadDir;
        WebUI.AuthSubnetWhitelist = "127.0.0.0/8";
        WebUI.AuthSubnetWhitelistEnabled = true;
        WebUI.HostHeaderValidationEnabled = false;
      };
    };

    # qBittorrent's download path lives on a FUSE mount managed by
    # the cococoir/garage clan-service
    # (`cococoir-fuse-<bucket>.service`). Wait for it to be active
    # before starting qBittorrent — without this, qBittorrent may
    # try to write to its download dir before the FUSE mount is up,
    # on a freshly-initialized cluster (first boot).
    systemd.services.qbittorrent.after = [ "cococoir-fuse-${cfg.bucket}.service" ];
  };
}
