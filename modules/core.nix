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

    adminUsers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          keys = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "SSH public keys for the user and root.";
          };
        };
      });
      default = {};
      description = "Admin users to create with wheel access and root SSH keys.";
    };

    localNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.0.0/16" ];
      description = ''
        CIDR ranges considered local/private. Services with public = false
        will only allow access from these ranges (via Caddy remote_ip matcher).
        Traffic from 127.0.0.1 (e.g. rathole tunnel) is implicitly excluded.
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

  config = {
    users.users = lib.mkMerge [
      (lib.mkIf (cfg.adminUsers != {}) (lib.mapAttrs (name: user: {
        isNormalUser = true;
        description = name;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = user.keys;
      }) cfg.adminUsers))

      (lib.mkIf (cfg.users != {}) (lib.mapAttrs (name: user: {
        isNormalUser = true;
        description = name;
        extraGroups = lib.optional user.isAdmin "wheel";
        openssh.authorizedKeys.keys = user.sshKeys;
        shell = if user.shell != null then user.shell else config.users.defaultUserShell;
      }) cfg.users))

      (lib.mkIf (cfg.adminUsers != {}) {
        root.openssh.authorizedKeys.keys =
          lib.flatten (lib.mapAttrsToList (_: user: user.keys) cfg.adminUsers);
      })
    ];
  };
}
