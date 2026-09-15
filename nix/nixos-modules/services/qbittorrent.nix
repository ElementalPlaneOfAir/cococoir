# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/qbittorrent — torrent client for the media stack.
#
# 3-option contract (metadata-only service, no bucket).
#
# Design decisions (see .specify/specs/media-automation-stack/):
#   - Web UI is the internal admin surface: `public` defaults to
#     false (Caddy 403s it; Seerr is the public face). Everything
#     binds 127.0.0.1.
#   - WebUI auth is bypassed for localhost: the entire control plane
#     (radarr, sonarr, the applier) is same-host, same trust domain;
#     no password to manage or leak.
#   - The download directory is the media subvolume's `downloads/`
#     dir (per-category save paths are created by the applier via
#     the qbt API — categories live in categories.json, which is not
#     conf-declarable). Strays (un-categorized torrents) land in the
#     profile dir, never inside the media tree.
#   - PrivateUsers is forced off: the nixpkgs unit's default maps
#     supplementary groups to nobody in the user namespace, which
#     would revoke qbittorrent's access to the jellyfin-group media
#     subvolumes (0770) — the group-sharing design would silently
#     fail. Tripwired in vmtest-wiring.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkFortressService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkFortressService {
  name = "qbittorrent";
  description = "qBittorrent torrent client";
  defaultPort = 8080;
  defaultHealthPath = "/api/v2/app/version";
  requires = ["jellyfin"];
  extraConfig = {
    lib,
    ...
  }: let
    torrentPort = 51413;
  in {
    fortress.services.qbittorrent.public = lib.mkDefault false;

    services.qbittorrent = {
      enable = true;
      openFirewall = false;
      user = "qbittorrent";
      group = "jellyfin";
      torrentingPort = torrentPort;
      serverConfig = {
        LegalNotice.Accepted = true;
        BitTorrent.Session = {
          DefaultSavePath = "/var/lib/qBittorrent/incomplete";
          GlobalMaxRatio = 5;
          GlobalMaxRatioAction = 0;
          AddExtensionToIncompleteFiles = true;
          Preallocation = true;
        };
        Preferences.WebUI = {
          Address = "127.0.0.1";
          LocalHostAuth = false;
          HostHeaderValidation = false;
          UseUPnP = false;
          CSRFProtection = true;
          SecureCookie = true;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [torrentPort];
    networking.firewall.allowedUDPPorts = [torrentPort];

    systemd.services.qbittorrent.serviceConfig = {
      PrivateUsers = lib.mkForce false;
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
