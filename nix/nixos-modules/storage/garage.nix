# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/storage — single-node Garage S3 daemon + bucket-init +
# per-bucket FUSE mounts for v2.
#
# Always-on (cococoir.storage.enable defaults to true). Every
# service that needs a bucket auto-declares it via the service
# module; the customer only sets the 5 secret file paths.
#
# The option surface is intentionally minimal — single-node
# ports, region, and layout are hardcoded. Multi-node support
# will justify its own option surface when it lands.
{ config,
  lib,
  pkgs,
  ... }:
let
  inherit (lib) mkOption mkEnableOption types;

  cfg = config.cococoir.storage;
  dataDir = "/var/lib/cococoir/garage/data";
  metaDir = "/var/lib/cococoir/garage/meta";
  globalDir = "/var/lib/cococoir/garage/global";
  s3ApiPort = 3900;
  rpcPort = 3901;
  adminPort = 3903;

  hasParentMount = fileSystems: mp:
    let parent = builtins.dirOf mp;
    in parent != "/" && parent != "." && fileSystems ? ${parent};

  parentMountUnit = mp: let
    parent = builtins.dirOf mp;
  in "${lib.replaceStrings [ "/" ] [ "-" ] parent}.mount";

  bucketNames = builtins.attrNames cfg.buckets;
  mountNames = builtins.attrNames cfg.mounts;

  fuseServices = lib.mapAttrs' (name: m: {
    name = "cococoir-fuse-${name}";
    value = {
      description = "FUSE mount of Garage bucket '${m.bucket}' to ${m.mountPoint}";
      wantedBy = [ "multi-user.target" ];
      after = [ "garage-bucket-init.service" ]
        ++ lib.optional (hasParentMount config.fileSystems m.mountPoint)
          "${parentMountUnit m.mountPoint}";
      requires = [ "garage-bucket-init.service" ];
      environment = {
        AWS_ACCESS_KEY_ID_FILE = cfg.secrets.accessKeyIdFile;
        AWS_SECRET_ACCESS_KEY_FILE = cfg.secrets.secretAccessKeyFile;
        AWS_REGION = "garage";
      };
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${m.mountPoint}";
        ExecStart = lib.concatMapStringsSep " " (s: lib.escapeShellArg s) [
          "${pkgs.geesefs}/bin/geesefs"
          m.bucket
          m.mountPoint
          "-o"
          (lib.concatStringsSep "," ([
            "allow_other"
            "default_permissions"
            "use_path_request_style"
            "url=http://127.0.0.1:${toString s3ApiPort}"
            "region=garage"
          ] ++ lib.optional m.readOnly "ro"))
        ];
        ExecStopPost = "-${pkgs.fuse3}/bin/fusermount3 -u ${m.mountPoint}";
        Restart = "on-failure";
        RestartSec = "10s";
        KillMode = "process";
      };
    };
  }) cfg.mounts;

  sopsKeyDir = builtins.dirOf cfg.secrets.accessKeyIdFile;
in {
  options.cococoir.storage = {
    enable = mkOption {
      type = types.bool;
      default = true;
      defaultText = "true";
      description = ''
        Enable the cococoir storage layer (Garage S3 daemon + FUSE
        mounts). **Always on** — the platform requires storage for
        every service that has a bucket. Customers do not need to
        set this option; it is `true` by default. Set to `false`
        only in a non-customer config (e.g. a test that doesn't
        need storage).
      '';
    };

    secrets = {
      rpcSecretFile = mkOption {
        type = types.path;
        description = "Path to the Garage RPC secret. Populated by sops-nix.";
      };
      adminTokenFile = mkOption {
        type = types.path;
        description = "Path to the Garage admin API token. Populated by sops-nix.";
      };
      metricsTokenFile = mkOption {
        type = types.path;
        description = "Path to the Garage metrics token. Populated by sops-nix.";
      };
      accessKeyIdFile = mkOption {
        type = types.path;
        description = "Path to the cluster-wide S3 access key id. Populated by sops-nix.";
      };
      secretAccessKeyFile = mkOption {
        type = types.path;
        description = "Path to the cluster-wide S3 secret access key. Populated by sops-nix.";
      };
    };

    buckets = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          replicationFactor = mkOption {
            type = types.ints.unsigned;
            default = 1;
            description = ''
              Requested replication factor. Single-node v2 is always 1.
            '';
          };
        };
      });
      default = { };
      description = ''
        Buckets to create. Service modules add their bucket here
        automatically when enabled; users do not need to declare
        buckets manually.
      '';
    };

    mounts = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          bucket = mkOption {
            type = types.str;
            description = "Name of the bucket to mount.";
          };
          mountPoint = mkOption {
            type = types.str;
            description = "Local filesystem path the bucket is FUSE-mounted at.";
          };
          readOnly = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the mount is read-only.";
          };
        };
      });
      default = { };
      description = ''
        FUSE mounts (geesefs) exposing buckets as local filesystems.
        Service modules add their mount here automatically.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = bucketNames != [ ];
        message = ''
          cococoir.storage: no buckets declared. Enable a cococoir
          service that needs storage (e.g. jellyfin, nextcloud).
        '';
      }
      {
        assertion = lib.all
          (m: builtins.elem cfg.mounts.${m}.bucket bucketNames)
          mountNames;
        message = let
          orphans = lib.filter
            (m: !(builtins.elem cfg.mounts.${m}.bucket bucketNames))
            mountNames;
        in ''
          cococoir.storage: mount(s) reference undeclared bucket(s):
          ${lib.concatStringsSep ", " (map
            (m: "${m} → \"${cfg.mounts.${m}.bucket}\"") orphans)}
          Declare the bucket via a service that uses it, or add it
          to cococoir.storage.buckets.
        '';
      }
    ];

    users.users.garage = {
      isSystemUser = true;
      group = "garage";
      home = metaDir;
      createHome = true;
    };
    users.groups.garage = { };

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0750 garage garage - -"
      "d ${metaDir} 0750 garage garage - -"
      "d ${globalDir} 0700 garage garage - -"
    ];

    services.garage = {
      enable = true;
      package = pkgs.garage;
      settings = {
        replication_factor = 1;
        data_dir = dataDir;
        metadata_dir = metaDir;
        rpc_bind_addr = "127.0.0.1:3901";
        rpc_public_addr = "127.0.0.1:3901";
        s3_api.api_bind_addr = "127.0.0.1:3900";
        s3_api.s3_region = "garage";
        s3_api.root_domain = "s3.garage.local";
        admin.api_bind_addr = "127.0.0.1:3903";
      };
    };

    systemd.services = {
      garage.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "garage";
        Group = "garage";
        LoadCredential = [
          "rpc_secret:${cfg.secrets.rpcSecretFile}"
          "admin_token:${cfg.secrets.adminTokenFile}"
          "metrics_token:${cfg.secrets.metricsTokenFile}"
        ];
        Environment = [
          "GARAGE_ALLOW_WORLD_READABLE_SECRETS=true"
          "GARAGE_RPC_SECRET_FILE=%d/rpc_secret"
          "GARAGE_ADMIN_TOKEN_FILE=%d/admin_token"
          "GARAGE_METRICS_TOKEN_FILE=%d/metrics_token"
        ];
      };

      garage-bucket-init = {
        description = "cococoir/garage bucket init: layout, S3 key, buckets";
        wantedBy = [ "multi-user.target" ];
        after = [ "garage.service" ];
        path = lib.mkAfter [
          pkgs.bash
          pkgs.garage
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = metaDir;
          ExecStart = lib.concatMapStringsSep " " lib.escapeShellArg (
            [
              "${./bucket-init.sh}"
              "--global-dir" globalDir
              "--address" "127.0.0.1:3901"
              "--zone" "z1"
              "--capacity" "1T"
            ]
            ++ lib.concatMap (b: [ "--bucket" b ]) bucketNames
          );
          LoadCredential = [
            "rpc_secret:${cfg.secrets.rpcSecretFile}"
          ];
          Environment = [
            "GARAGE_RPC_SECRET_FILE=%d/rpc_secret"
            "COCOCOIR_S3_KEY_DIR=${sopsKeyDir}"
          ];
        };
      };
    } // fuseServices;
  };
}
