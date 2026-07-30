# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/lidarr — Music management.
#
# 3-option contract (metadata-only service, no bucket).
{config, lib, pkgs, options, ...}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "lidarr";
  description = "Lidarr music management";
  defaultPort = 8686;
  defaultHealthPath = "/ping";
  extraConfig = {lib, ...}: {
    services.lidarr = {
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
