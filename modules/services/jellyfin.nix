{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.services.jellyfin;
  domain = config.cococoir.domain;
in
{
  options.cococoir.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    domain = lib.mkOption {
      type = lib.types.str;
      default = if domain != null then "jellyfin.${domain}" else "jellyfin.local";
      description = "Public domain for Jellyfin.";
    };

    globallyAccessible = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose Jellyfin on the public domain via Caddy.";
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

    services.caddy.virtualHosts = lib.mkMerge [
      {
        "http://jellyfin.${config.networking.hostName}.internal".extraConfig = ''
          reverse_proxy localhost:8096
        '';
      }
      (lib.mkIf cfg.globallyAccessible {
        "${cfg.domain}".extraConfig = ''
          reverse_proxy localhost:8096
        '';
      })
    ];
  };
}
