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
#     no password to manage or leak. The human-facing boundary is the
#     Dex gate (`accessGroup = "arr"`), not a qBittorrent login.
#   - The download directory is the media subvolume's `downloads/`
#     dir (per-category save paths are created by the applier via
#     the qbt API — categories live in categories.json, which is not
#     conf-declarable). Strays (un-categorized torrents) land in the
#     profile dir, never inside the media tree.
#   - Runs as root (ADR-036): the applier cannot create the
#     qbittorrent account this unit used to name, so it takes the
#     portable stable identity instead.
#   - PrivateUsers is forced off (tripwired in vmtest-wiring): the
#     nixpkgs unit's default user namespace revokes access to the
#     0770 media subvolumes.
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
  # qBittorrent's WebUI serves at / and has no base-path knob, so the
  # reverse proxy must strip /qbittorrent or every request 404s.
  stripPath = true;
  requires = ["jellyfin"];
  accessGroup = "arr";
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
      user = "root";
      group = "root";
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
          # Bypass auth for localhost — the value this comment always
          # described but the config never set. qBittorrent has no
          # "trust the reverse proxy" mode, so this IS the posture: the
          # app trusts the loopback source and the Dex gate (caddy
          # `forward_auth`, planes.nix) is the only thing between a LAN
          # client and the WebUI. It binds 127.0.0.1 only, so the reachable
          # surface is the gate. Woe betide a route that loses its gate:
          # asserted in applier-wiring.
          LocalHostAuth = true;
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
      # qBittorrent does not create DefaultSavePath on startup, and an
      # absent one is a permanent `error` in radarr/sonarr's health
      # ("cannot see this directory") — not a transient. Make it exist.
      ExecStartPre = lib.mkAfter ["+${pkgs.coreutils}/bin/mkdir -p /var/lib/qBittorrent/incomplete"];
    };
  };
}
