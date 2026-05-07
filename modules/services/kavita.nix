{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.services.kavita;
in
{
  options.cococoir.services.kavita = {
    enable = lib.mkEnableOption "Kavita reading server";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Kavita.";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to Kavita.";
    };

    tokenKeyFile = lib.mkOption {
      type = lib.types.path;
      default = config.clan.core.vars.generators.kavita-token.files.token-key.path;
      description = ''
        Path to a file containing the Kavita TokenKey (512+ bits).
        Defaults to a Clan secret generator.
      '';
    };
  };

  config = {
    clan.core.vars.generators.kavita-token = {
      files.token-key = {};
      script = ''
        head -c 64 /dev/urandom | base64 --wrap=0 > $out/token-key
      '';
      runtimeInputs = [ pkgs.coreutils ];
    };

    services.kavita = lib.mkIf cfg.enable {
      enable = true;
      tokenKeyFile = cfg.tokenKeyFile;
      settings = {
        IpAddresses = "127.0.0.1";
        Port = 5000;
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig = lib.mkIf cfg.enable (
      if cfg.public
      then ''reverse_proxy localhost:5000''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:5000
      ''
    );
  };
}
