# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/radarr — Movie management.
#
# 3-option contract (metadata-only service, no bucket):
#   enable  — opt-in toggle
#   domain  — external FQDN for the Caddy vhost
#   public  — true → Caddy reverse-proxies; false → 403
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "radarr";
  description = "Radarr movie management";
  defaultPort = 7878;
  defaultHealthPath = "/ping";
  requires = ["jellyfin"];
  extraConfig = {lib, ...}: {
    services.radarr = {
      enable = true;
      openFirewall = false;
      settings = {
        server.bindAddress = "127.0.0.1";
        update.automatically = false;
        log.analyticsEnabled = false;
      };
    };
  };
}
