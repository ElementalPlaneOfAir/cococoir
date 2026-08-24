# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/sonarr — TV show management.
#
# 3-option contract (metadata-only service, no bucket).
{config, lib, pkgs, options, ...}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "sonarr";
  description = "Sonarr TV show management";
  defaultPort = 8989;
  defaultHealthPath = "/ping";
  requires = ["jellyfin"];
  extraConfig = {lib, ...}: {
    services.sonarr = {
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
