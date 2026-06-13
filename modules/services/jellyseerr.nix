{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cococoir.services.jellyseerr;
  port = 5055;
  dataDir = "/var/lib/jellyseerr";
  user = "jellyseerr";
  group = "jellyseerr";
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
    users.users.${user} = {
      isSystemUser = true;
      home = dataDir;
      group = group;
      description = "Jellyseerr system user";
    };
    users.groups.${group} = {};

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 ${user} ${group} -"
    ];

    systemd.services.jellyseerr = {
      description = "Jellyseerr media request UI";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      environment = {
        LOG_LEVEL = "info";
        PORT = toString port;
        CONFIG_DIR = dataDir;
        DATA_DIR = dataDir;
        TZ = "UTC";
      };
      serviceConfig = {
        ExecStart = "${pkgs.seerr}/bin/seerr";
        User = user;
        Group = group;
        WorkingDirectory = dataDir;
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "jellyseerr";
      };
    };

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
