{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.services.mautrix-gmessages;
  dataDir = "/var/lib/mautrix-gmessages";
  registrationFile = "${dataDir}/gmessages-registration.yaml";
  settingsFile = "${dataDir}/config.yaml";
  settingsFormat = pkgs.formats.json { };
  appservicePort = 29336;

  mkDefaults = lib.mapAttrsRecursive (n: v: lib.mkDefault v);
  defaultConfig = {
    network = {
      displayname_template = "{{or .FullName .PhoneNumber}}";
      device_meta = {
        os = "mautrix-gmessages";
        browser = "OTHER";
        type = "TABLET";
      };
      aggressive_reconnect = false;
      initial_chat_sync_count = 25;
      ping_interval = "20m";
      alert_timeout_count = 4;
    };
    bridge = {
      command_prefix = "!gm";
      personal_filtering_spaces = true;
      private_chat_portal_meta = true;
      permissions = {
        "*" = "relay";
      };
    };
    database = {
      type = "postgres";
      uri = "postgres:///mautrix-gmessages?host=/run/postgresql";
    };
    homeserver = {
      address = "http://127.0.0.1:6167";
      domain = config.cococoir.domain;
      software = "standard";
    };
    appservice = {
      hostname = "127.0.0.1";
      port = appservicePort;
      id = "gmessages";
      bot = {
        username = "gmessagesbot";
        displayname = "Google Messages bridge bot";
      };
      as_token = "";
      hs_token = "";
      username_template = "gmessages_{{.}}";
    };
    double_puppet = {
      servers = { };
      secrets = { };
    };
    encryption = {
      allow = false;
      default = false;
      require = false;
      pickle_key = "";
    };
    provisioning = {
      shared_secret = "";
    };
    public_media = {
      enabled = false;
      signing_key = "";
    };
    logging = {
      min_level = "info";
      writers = lib.singleton {
        type = "stdout";
        format = "pretty-colored";
      };
    };
  };

  settingsFileUnsubstituted = settingsFormat.generate "mautrix-gmessages-config-unsubstituted.json" cfg.settings;
in
{
  options.cococoir.services.mautrix-gmessages = {
    enable = lib.mkEnableOption "mautrix-gmessages, a Matrix-Google Messages puppeting bridge";

    settings = lib.mkOption {
      apply = lib.recursiveUpdate defaultConfig;
      type = settingsFormat.type;
      default = defaultConfig;
      description = ''
        {file}`config.yaml` configuration as a Nix attribute set.
        Configuration options should match those described in the example configuration.
        Secret tokens should be specified using {option}`environmentFile`
        instead of this world-readable attribute set.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing environment variables to be passed to the mautrix-gmessages service.
        This can be used for storing secrets without leaking them to the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL database for the bridge
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "mautrix-gmessages" ];
      ensureUsers = [
        {
          name = "mautrix-gmessages";
          ensureDBOwnership = true;
        }
      ];
    };

    # Bridge user & group
    users.users.mautrix-gmessages = {
      isSystemUser = true;
      group = "mautrix-gmessages";
      home = dataDir;
      description = "mautrix-gmessages bridge user";
    };
    users.groups.mautrix-gmessages = { };

    # Ensure domain permission defaults to user level
    cococoir.services.mautrix-gmessages.settings.bridge.permissions =
      lib.mkDefault (lib.optionalAttrs (config.cococoir.domain != null) {
        "${config.cococoir.domain}" = "user";
      });

    systemd.services.mautrix-gmessages = {
      description = "mautrix-gmessages, a Matrix-Google Messages puppeting bridge";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" "continuwuity.service" ];
      after = [ "network-online.target" "continuwuity.service" "postgresql.service" ];
      requires = [ "postgresql.service" ];

      preStart = ''
        # Substitute environment variables into the config file
        test -f '${settingsFile}' && rm -f '${settingsFile}'
        old_umask=$(umask)
        umask 0177
        ${pkgs.envsubst}/bin/envsubst \
          -o '${settingsFile}' \
          -i '${settingsFileUnsubstituted}'
        umask $old_umask

        # Generate appservice registration if absent
        if [ ! -f '${registrationFile}' ]; then
          ${pkgs.mautrix-gmessages}/bin/mautrix-gmessages \
            --generate-registration \
            --config='${settingsFile}' \
            --registration='${registrationFile}'
        fi
        chmod 640 ${registrationFile}

        # Sync tokens from registration back into config
        umask 0177
        ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
          | .[0].appservice.hs_token = .[1].hs_token
          | .[0]' \
          '${settingsFile}' '${registrationFile}' > '${settingsFile}.tmp'
        mv '${settingsFile}.tmp' '${settingsFile}'
        umask $old_umask
      '';

      serviceConfig = {
        User = "mautrix-gmessages";
        Group = "mautrix-gmessages";
        EnvironmentFile = cfg.environmentFile;
        StateDirectory = baseNameOf dataDir;
        WorkingDirectory = dataDir;
        ExecStart = ''
          ${pkgs.mautrix-gmessages}/bin/mautrix-gmessages \
          --config='${settingsFile}' \
          --registration='${registrationFile}'
        '';
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        Restart = "on-failure";
        RestartSec = "30s";
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallErrorNumber = "EPERM";
        SystemCallFilter = [ "@system-service" ];
        Type = "simple";
        UMask = 27;
      };
      restartTriggers = [ settingsFileUnsubstituted ];
    };
  };
}
