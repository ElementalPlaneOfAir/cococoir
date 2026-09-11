# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/services/prowlarr — Indexer management for *arr stack.
#
# 3-option contract (metadata-only service, no bucket).
{config, lib, pkgs, options, ...}:
let
  mkFortressService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkFortressService {
  name = "prowlarr";
  description = "Prowlarr indexer management";
  defaultPort = 9696;
  defaultHealthPath = "/ping";
  requires = ["jellyfin"];
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
