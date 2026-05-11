{ config, lib, ... }:
let
  cfg = config.cococoir.services.octoprint;
in
{
  options.cococoir.services.octoprint = {
    enable = lib.mkEnableOption "OctoPrint 3D printer web interface";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for OctoPrint.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to OctoPrint.";
    };

    obico = {
      enable = lib.mkEnableOption "Obico AI print failure detection plugin";

      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "https://app.obico.io";
        description = ''
          Obico server endpoint URL. Set to your self-hosted Obico server
          if not using Obico Cloud.
        '';
      };

      authToken = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Obico printer authentication token. If null, the printer must be
          linked manually via the OctoPrint setup wizard.
        '';
      };

      disableVideoStreaming = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable video streaming to Obico.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.octoprint = {
      enable = true;
      host = "127.0.0.1";
      port = 5321;
      openFirewall = false;
      plugins = plugins: lib.optional cfg.obico.enable plugins.obico;
      extraConfig = lib.mkMerge [
        (lib.mkIf config.cococoir.adminAuth.enable {
          accessControl = {
            autologinLocal = true;
            autologinAs = "admin";
            localNetworks = [ "127.0.0.1/8" ];
          };
        })
        (lib.mkIf cfg.obico.enable {
          plugins.obico = {
            endpoint_prefix = cfg.obico.endpoint;
            disable_video_streaming = cfg.obico.disableVideoStreaming;
          } // lib.optionalAttrs (cfg.obico.authToken != null) {
            auth_token = cfg.obico.authToken;
          };
        })
      ];
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      config.lib.cococoir.withAuth (
        if cfg.public
        then ''reverse_proxy localhost:5321''
        else ''
          @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
          respond @not_local "Forbidden" 403
          reverse_proxy localhost:5321
        ''
      );
  };
}
