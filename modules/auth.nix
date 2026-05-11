{ config, lib, ... }:
let
  cfg = config.cococoir.adminAuth;
in
{
  options.cococoir.adminAuth = {
    enable = lib.mkEnableOption "admin HTTP Basic Authentication for admin services";
    users = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Map of usernames to bcrypt-hashed passwords for admin authentication.
        Generate hashes with `mkpasswd -m bcrypt` or `openssl passwd - bcrypt`.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = !cfg.enable || cfg.users != {};
        message = "cococoir.adminAuth.users must not be empty when adminAuth is enabled.";
      }
    ];

    lib.cococoir.withAuth = extraConfig:
      if cfg.enable then ''
        basicauth {
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (user: hash: "  ${user} ${hash}") cfg.users)}
        }
        ${extraConfig}
      '' else extraConfig;
  };
}
