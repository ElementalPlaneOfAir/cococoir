{ config, lib, ... }:
let
  cfg = config.cococoir.services.custom;
in
{
  options.cococoir.services.custom = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "this custom service";

        domain = lib.mkOption {
          type = lib.types.str;
          description = "External domain for the service.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          description = "Local port the service listens on.";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          description = "Whether to allow public access to the service.";
        };
      };
    });
    default = {};
    description = "Custom services to expose via Caddy reverse proxy.";
  };

  config.services.caddy.virtualHosts = lib.mkMerge (lib.mapAttrsToList (_: svc:
    lib.mkIf svc.enable {
      "${svc.domain}".extraConfig =
        if svc.public
        then ''reverse_proxy localhost:${toString svc.port}''
        else ''
          @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
          respond @not_local "Forbidden" 403
          reverse_proxy localhost:${toString svc.port}
        '';
    }
  ) cfg);
}
