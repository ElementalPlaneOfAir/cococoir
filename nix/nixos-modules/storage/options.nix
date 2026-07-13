# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/storage — option tree for the v2 home server storage layer.
#
# This is the user-facing surface. The user (or a service module)
# declares buckets and FUSE mounts; the `garage.nix` module reads
# them and wires up the daemon, the bucket-init oneshot, and the
# FUSE mount services.
#
# Ported from v1/storage/buckets.nix. The option shape is preserved
# (see v1/AGENTS.md, the 4-option service contract applies to
# service modules; this is the storage side of the same convention).
# The change from v1: `derived` is computed at evaluation time
# (config-driven, not clan-instance-driven), and bucket settings
# are an empty submodule with reserved options for the future.
{
  lib,
  ...
}: {
  options.cococoir.storage = {
    enable = lib.mkEnableOption "cococoir storage (Garage S3 + FUSE mounts)";

    cluster = {
      rpcBindAddr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:3901";
        description = "Address Garage's RPC binds to (internal cluster traffic).";
      };
      rpcPublicAddr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:3901";
        description = "Address Garage advertises to peers. For single-node, same as rpcBindAddr.";
      };
      s3ApiBindAddr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:3900";
        description = "Address the S3 API binds to. Service modules connect to this.";
      };
      adminApiBindAddr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:3903";
        description = "Address the admin API binds to. The bucket-init script talks to this.";
      };
      region = lib.mkOption {
        type = lib.types.str;
        default = "garage";
        description = "S3 region name. Used for both the cluster and the FUSE mount option.";
      };
    };

    node = {
      id = lib.mkOption {
        type = lib.types.str;
        default = "node-1";
        description = "Identifier for this node (visible in cluster status, logs).";
      };
      address = lib.mkOption {
        type = lib.types.str;
        example = "127.0.0.1:3901";
        description = "This node's RPC address. For single-node, same as cluster.rpcBindAddr.";
      };
      zone = lib.mkOption {
        type = lib.types.str;
        default = "z1";
        description = "Layout zone this node belongs to.";
      };
      capacity = lib.mkOption {
        type = lib.types.str;
        default = "1T";
        description = "Storage capacity this node contributes to its zone.";
      };
    };

    secrets = {
      rpcSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the Garage RPC secret. Populated by sops-nix.";
      };
      adminTokenFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the Garage admin API token. Populated by sops-nix.";
      };
      metricsTokenFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the Garage metrics token. Populated by sops-nix.";
      };
      accessKeyIdFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the cluster-wide S3 access key id. Populated by sops-nix.";
      };
      secretAccessKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the cluster-wide S3 secret access key. Populated by sops-nix.";
      };
    };

    buckets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          replicationFactor = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 1;
            description = ''
              Requested replication factor. Clamped to the number of layout
              zones with non-zero capacity at evaluation time.
            '';
          };
        };
      });
      default = { };
      description = ''
        Buckets to create. Service modules add their bucket here
        automatically when enabled; users do not need to declare
        buckets manually. Override only to share a bucket between
        services (e.g. jellyfin and qBittorrent both using "media")
        or to set per-bucket settings.
      '';
    };

    mounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          bucket = lib.mkOption {
            type = lib.types.str;
            description = "Name of the bucket to mount.";
          };
          mountPoint = lib.mkOption {
            type = lib.types.str;
            description = "Local filesystem path the bucket is FUSE-mounted at.";
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the mount is read-only.";
          };
        };
      });
      default = { };
      description = ''
        FUSE mounts (geesefs) exposing buckets as local filesystems.
        Service modules add their mount here automatically; override
        only to mount a bucket at multiple points.
      '';
    };

    derived = lib.mkOption {
      default = { };
      description = ''
        Read-only resolved view, written by the storage module after
        evaluating the cluster. Service modules consume this (e.g.
        nextcloud reads `derived.buckets.<bucket>.{endpoint, region, …}`).
        Do not set these from a service module.
      '';
      type = lib.types.submodule {
        options = {
          gatewayAddress = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "S3 gateway address (host:port).";
          };
          buckets = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                name = lib.mkOption { type = lib.types.str; };
                endpoint = lib.mkOption { type = lib.types.str; };
                host = lib.mkOption { type = lib.types.str; };
                port = lib.mkOption { type = lib.types.int; };
                region = lib.mkOption { type = lib.types.str; };
                accessKeyIdFile = lib.mkOption { type = lib.types.path; };
                secretAccessKeyFile = lib.mkOption { type = lib.types.path; };
                replicationFactor = lib.mkOption { type = lib.types.ints.unsigned; };
                intendedReplicationFactor = lib.mkOption { type = lib.types.ints.unsigned; };
              };
            });
          };
          mounts = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                mountPoint = lib.mkOption { type = lib.types.str; };
                readOnly = lib.mkOption { type = lib.types.bool; default = false; };
              };
            });
          };
        };
      };
    };
  };
}
