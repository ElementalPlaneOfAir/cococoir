{ config, lib, ... }:
let
  cfg = config.cococoir.services.vaultwarden;
in
{
  options.cococoir.services.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden password manager";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Vaultwarden.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Vaultwarden.";
    };

    signupsAllowed = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to allow new signups.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;
      config = {
        DOMAIN = "https://${cfg.domain}";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        SIGNUPS_ALLOWED = cfg.signupsAllowed;
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:8222''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:8222
      '';
  };
}
