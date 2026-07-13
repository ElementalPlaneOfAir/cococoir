# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/storage/garage — the Garage daemon + bucket-init oneshot +
# per-mount FUSE services for v2.
#
# Ported from v1/clan-services/garage/default.nix. The change from
# v1: clan-core's var generators are replaced with file-path options
# populated by sops-nix at the user's machine config level. The
# storage module never owns secret material.
#
# This module is single-node only. Multi-node cluster expansion is
# v4 work. The option surface and assertions assume one node, one
# zone.
#
# What this module produces (when cococoir.storage.enable = true):
#   - Static `garage` system user + persistent data/meta/global dirs
#   - nixpkgs services.garage, hardened (LoadCredential, static user)
#   - `garage-bucket-init.service`: idempotent first-boot setup that
#     adds bootstrap_peers, applies the layout, imports the S3 key,
#     creates buckets, allows the global key on each
#   - One `cococoir-fuse-<bucket>.service` per cococoir.storage.mounts
#     entry, FUSE-mounting the bucket via geesefs
#   - `cococoir.storage.derived.{gatewayAddress, buckets, mounts}`
#     for service modules to consume
{ config,
  lib,
  pkgs,
  ... }:
let
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

  # Clamp a requested RF to the number of layout zones. v2 is
  # single-node / single-zone, so the clamped RF is always 1; the
  # clamp is preserved for forward-compat with multi-node v4.
  clampedRF = requested: 1;

  fuseServices = lib.mapAttrs' (name: m: {
    name = "cococoir-fuse-${name}";
    value = {
      description = "FUSE mount of Garage bucket '${m.bucket}' to ${m.mountPoint}";
      wantedBy = [ "multi-user.target" ];
      after = [ "garage-bucket-init.service" ]
        ++ lib.optional (hasParentMount config.fileSystems m.mountPoint)
          "${parentMountUnit m.mountPoint}";
      requires = [ "garage-bucket-init.service" ];
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
            "region=${cfg.cluster.region}"
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
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.node ? address && cfg.node.address != "";
        message = "cococoir.storage: cococoir.storage.node.address is required.";
      }
      {
        assertion = bucketNames != [ ];
        message = ''
          cococoir.storage: no buckets declared. Enable a cococoir
          service that needs storage (e.g. jellyfin, nextcloud) or
          set cococoir.storage.buckets directly.
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
        rpc_bind_addr = cfg.cluster.rpcBindAddr;
        rpc_public_addr = cfg.node.address;
        s3_api.api_bind_addr = cfg.cluster.s3ApiBindAddr;
        s3_api.s3_region = cfg.cluster.region;
        admin.api_bind_addr = cfg.cluster.adminApiBindAddr;
        s3_api.root_domain = "s3.${cfg.cluster.region}.local";
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
              "--address" cfg.node.address
              "--zone" cfg.node.zone
              "--capacity" cfg.node.capacity
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

    cococoir.storage.derived = {
      gatewayAddress = "127.0.0.1:${toString s3ApiPort}";
      buckets = lib.mapAttrs (n: b: {
        name = n;
        endpoint = "http://127.0.0.1:${toString s3ApiPort}";
        host = "127.0.0.1";
        port = s3ApiPort;
        region = cfg.cluster.region;
        accessKeyIdFile = cfg.secrets.accessKeyIdFile;
        secretAccessKeyFile = cfg.secrets.secretAccessKeyFile;
        intendedReplicationFactor = b.replicationFactor;
        replicationFactor = clampedRF b.replicationFactor;
      }) cfg.buckets;
      mounts = lib.mapAttrs' (_: m: {
        name = m.bucket;
        value = {
          mountPoint = m.mountPoint;
          readOnly = m.readOnly;
        };
      }) cfg.mounts;
    };
  };
}
