{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.services.jellyfin;
in
{
  options.cococoir.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Jellyfin.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Jellyfin.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
    };

    users.groups.jellyfin = {};
    users.users.jellyfin = {
      isSystemUser = true;
      description = "Jellyfin System User";
      shell = lib.mkDefault pkgs.bash;
      extraGroups = [ "render" "video" ];
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:8096''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:8096
      '';
  };
}
