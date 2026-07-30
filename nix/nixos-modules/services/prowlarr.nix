# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/prowlarr — Indexer management for *arr stack.
#
# 3-option contract (metadata-only service, no bucket).
{config, lib, pkgs, options, ...}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "prowlarr";
  description = "Prowlarr indexer management";
  defaultPort = 9696;
  defaultHealthPath = "/ping";
  extraConfig = {lib, ...}: {
    services.prowlarr = {
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
