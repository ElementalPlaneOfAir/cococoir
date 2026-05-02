{ lib, config, ... }:
let
  cfg = config.cococoir;
in
{
  options.cococoir = {
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Base domain for all globally accessible services.
        Services default to <service-name>.''${domain} when enabled.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          isAdmin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the user should be in the wheel group.";
          };
          sshKeys = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "SSH public keys for the user.";
          };
          shell = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Login shell for the user. Defaults to bash.";
          };
        };
      });
      default = {};
      description = "Users to create on all machines importing this module.";
    };
  };

  config = lib.mkMerge [
    # Create users from cococoir.users
    (lib.mkIf (cfg.users != {}) {
      users.users = lib.mapAttrs (name: user: {
        isNormalUser = true;
        description = name;
        extraGroups = lib.optional user.isAdmin "wheel";
        openssh.authorizedKeys.keys = user.sshKeys;
        shell = if user.shell != null then user.shell else config.users.defaultUserShell;
      }) cfg.users;
    })
  ];
}
