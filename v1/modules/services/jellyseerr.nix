# SPDX-License-Identifier: AGPL-3.0-or-later
{
  config,
  lib,
  ...
}: let
  cfg = config.cococoir.services.jellyseerr;
  port = 5055;
in {
  options.cococoir.services.jellyseerr = {
    enable = lib.mkEnableOption "Jellyseerr (seerr) media request and discovery UI";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Jellyseerr.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Jellyseerr.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.seerr = {
      enable = true;
      openFirewall = false;
      port = port;
    };

    # Bind to localhost: nixpkgs' services.seerr listens on 0.0.0.0 by
    # default; Cococoir services are reached via the Caddy reverse
    # proxy on 127.0.0.1, not directly.
    systemd.services.seerr.environment.HOST = "127.0.0.1";

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy 127.0.0.1:${toString port}''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy 127.0.0.1:${toString port}
      '';
  };
}
