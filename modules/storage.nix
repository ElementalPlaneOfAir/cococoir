# SPDX-License-Identifier: MIT
{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.storage;

  # ── Submodule types ───────────────────────────────────────────────────────
  zoneType = lib.types.submodule {
    options = {
      id = lib.mkOption {
        type = lib.types.str;
        description = ''
          Zone identifier (e.g. "z1", "dc-east", "rack-A"). Used as the
          Garage zone label. Each node is assigned to exactly one zone.
        '';
      };
      capacity = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
        default = null;
        description = ''
          Total storage capacity (in bytes) this zone reports to Garage's
          layout engine. Set to null for zero-capacity zones (gateway-only
          nodes that don't store data but still need to be in the cluster).
          String values must be parseable by Garage: "100G", "2T", etc.
        '';
      };
    };
  };

  bucketType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      replicationFactor = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
        description = ''
          How many copies of every object to keep. Clamped at eval time to
          the number of zones with non-zero capacity. A 1-machine / 1-zone
          cluster asking for RF=3 gets RF=1 and a loud assertion (not a
          silent degradation) so you notice the data isn't as redundant
          as you thought.
        '';
      };

      quotas = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            maxSize = lib.mkOption {
              type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
              default = null;
              description = "Maximum total size (e.g. \"500G\"). null = unlimited.";
            };
            maxObjects = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.unsigned;
              default = null;
              description = "Maximum number of objects. null = unlimited.";
            };
          };
        });
        default = null;
      };

      website = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            index = lib.mkOption {
              type = lib.types.str;
              default = "index.html";
            };
            error = lib.mkOption {
              type = lib.types.str;
              default = "error.html";
            };
          };
        });
        default = null;
        description = ''
          Optional S3 static-website hosting. When set, Garage serves
          the bucket on the S3 API port as a website.
        '';
      };

      # Internal: populated by the runtime bucket-init oneshot, not by users.
      _accessKeyId = lib.mkOption {
        type = lib.types.str;
        internal = true;
        visible = false;
        default = "";
        description = "Internal: the global access key id for this bucket.";
      };
      _secretAccessKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        internal = true;
        visible = false;
        default = null;
        description = "Internal: path to the S3 secret access key file.";
      };
    };
    config.name = lib.mkDefault name;
  });

  mountType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        description = "Name of the bucket to mount (must be a key in cococoir.storage.buckets).";
      };
      mountPoint = lib.mkOption {
        type = lib.types.path;
        description = "Absolute path where the bucket should appear.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.geesefs;
        defaultText = lib.literalExpression "pkgs.geesefs";
        description = "FUSE implementation. Default: geesefs (preferred over s3fs per project plan).";
      };
      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--memory-limit=1000" "--debug" ];
        description = "Extra command-line options passed to the FUSE binary.";
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
    config.name = lib.mkDefault name;
  });

  # ── Derived state ─────────────────────────────────────────────────────────
  enabledBuckets = lib.filter (b: b.enable) (lib.attrValues cfg.buckets);
  enabledMounts = lib.filterAttrs (_: m: m.enable) cfg.mounts;
  zoneIds = map (z: z.id) cfg.cluster.layout.zones;
  zonesWithCapacity = lib.filter (z: z.capacity != null && z.capacity != 0)
    cfg.cluster.layout.zones;
  numZonesWithCapacity = builtins.length zonesWithCapacity;

  # ── Per-bucket RF clamping ────────────────────────────────────────────────
  clampedBuckets = lib.listToAttrs (map (b: {
    name = b.name;
    value = b // {
      _intendedRF = b.replicationFactor;
      _clampedRF =
        if b.replicationFactor <= numZonesWithCapacity
        then b.replicationFactor
        else if numZonesWithCapacity == 0
        then 1
        else numZonesWithCapacity;
    };
  }) enabledBuckets);

  # ── Local peers (everything in bootstrapPeers except this node) ───────────
  localPeers = lib.filter (p: p != cfg.node.address) cfg.cluster.bootstrapPeers;

  # Split host:port for the local address
  localHost = builtins.elemAt (lib.splitString ":" cfg.node.address) 0;

  # ── Derived view (read by native-S3 apps) ─────────────────────────────────
  derivedBuckets = lib.mapAttrs (_: b: {
    name = b.name;
    endpoint = "http://${cfg.node.address}:${toString cfg.cluster.s3ApiPort}";
    region = cfg.cluster.region;
    accessKeyId = b._accessKeyId;
    secretAccessKeyFile = b._secretAccessKeyFile;
    replicationFactor = b._clampedRF;
    intendedReplicationFactor = b._intendedRF;
  }) clampedBuckets;

in
{
  options.cococoir.storage = {
    enable = lib.mkEnableOption "Cococoir distributed object storage (Garage S3)";

    cluster = {
      clusterId = lib.mkOption {
        type = lib.types.str;
        default = "cococoir";
        description = ''
          Logical cluster identifier. Used as a namespace prefix for
          resources (bucket aliases, etc.) and to make it obvious which
          cluster you're talking to when running multiple.
        '';
      };

      rpcSecretFile = lib.mkOption {
        type = lib.types.path;
        default = config.clan.core.vars.generators.storage-rpc-secret.files.rpc-secret.path;
        defaultText = lib.literalExpression
          "config.clan.core.vars.generators.storage-rpc-secret.files.rpc-secret.path";
        description = ''
          Path to the cluster's shared RPC secret. Defaults to the
          clan vars generator (storage-vars.nix). All nodes in the
          cluster must use the same value; clan handles the distribution
          via its shared=true flag.
        '';
      };

      s3ApiPort = lib.mkOption {
        type = lib.types.port;
        default = 3900;
      };

      rpcPort = lib.mkOption {
        type = lib.types.port;
        default = 3901;
      };

      adminPort = lib.mkOption {
        type = lib.types.port;
        default = 3903;
      };

      region = lib.mkOption {
        type = lib.types.str;
        default = "garage";
      };

      bootstrapPeers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.168.1.10:3901" "192.168.1.11:3901" "192.168.1.12:3901" ];
        description = ''
          Full list of peer RPC addresses (host:rpcPort) in the cluster.
          The local node's own address is filtered out at eval time.
          On a single-node cluster, leave this empty.
        '';
      };

      layout.zones = lib.mkOption {
        type = lib.types.listOf zoneType;
        default = [ ];
        example = [
          { id = "z1"; capacity = "4T"; }
          { id = "z2"; capacity = "4T"; }
          { id = "z3"; capacity = "4T"; }
        ];
        description = ''
          Full topology of the cluster. Used to clamp per-bucket
          replication factors at eval time. The local node's zone must
          appear in this list.
        '';
      };
    };

    node = {
      id = lib.mkOption {
        type = lib.types.str;
        description = ''
          Stable identifier for this node. Set explicitly in each
          machine's configuration. Must be unique within the cluster.
          Garage's `node id` is generated from this by the runtime
          bucket-init service; you don't need to manage garage's
          internal id separately.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        example = "192.168.1.10:3901";
        description = ''
          Address other nodes use to reach THIS node's RPC, formatted
          host:rpcPort. Must be reachable from every peer.
        '';
      };

      zone = lib.mkOption {
        type = lib.types.str;
        description = ''
          The zone this node belongs to. Must match an id in
          cococoir.storage.cluster.layout.zones.
        '';
      };

      dataDir = lib.mkOption {
        type = lib.types.path;
        example = "/var/lib/garage/data";
      };

      metaDir = lib.mkOption {
        type = lib.types.path;
        example = "/var/lib/garage/meta";
        description = ''
          Where Garage stores its metadata database. Put this on a fast
          disk (SSD) if possible; dataDir may be on a slower HDD.
        '';
      };

      capacity = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
        default = null;
        description = ''
          How much of the zone's total capacity this node contributes.
          null means this is a gateway-only node (no local storage).
        '';
      };
    };

    buckets = lib.mkOption {
      type = lib.types.attrsOf bucketType;
      default = { };
      description = ''
        Declarative S3 buckets. Per-bucket replicationFactor is clamped
        to the number of zones with non-zero capacity; an assertion fires
        at eval time if any bucket's intended RF exceeds the topology.
      '';
    };

    mounts = lib.mkOption {
      type = lib.types.attrsOf mountType;
      default = { };
      description = ''
        Optional FUSE mount points that present a bucket as a POSIX
        filesystem (via geesefs). For native-S3 apps, read the
        credentials from cococoir.storage.derived.buckets.<name> instead.
      '';
    };

    derived = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      internal = true;
      visible = false;
      readOnly = true;
      default = { };
      description = "Internal: derived values populated at eval time.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (import ./storage/garage.nix {
      inherit lib pkgs;
      inherit cfg localPeers localHost numZonesWithCapacity;
    })

    (import ./storage/bucket.nix {
      inherit lib pkgs;
      inherit cfg clampedBuckets;
    })

    (import ./storage/fuse.nix {
      inherit lib pkgs;
      inherit cfg enabledMounts localHost;
    })

    {
      cococoir.storage.derived = {
        buckets = derivedBuckets;
        gatewayAddress = "${localHost}:${toString cfg.cluster.s3ApiPort}";
      };

      assertions =
        lib.optionals (cfg.node.zone != "" && !(builtins.elem cfg.node.zone zoneIds))
        [{
          assertion = builtins.elem cfg.node.zone zoneIds;
          message = ''
            cococoir.storage.node.zone = "${cfg.node.zone}" but no matching zone
            is defined in cococoir.storage.cluster.layout.zones.
            Add a zone with id = "${cfg.node.zone}" or fix the node.zone value.
          '';
        }]
        ++ lib.optionals (cfg.node.capacity != null && !(builtins.elem cfg.node.zone zoneIds))
        [{
          assertion = builtins.elem cfg.node.zone zoneIds;
          message = ''
            cococoir.storage.node.capacity is set but node.zone =
            "${cfg.node.zone}" is not in cluster.layout.zones.
          '';
        }]
        ++ map (b: {
          assertion = b._clampedRF >= 1;
          message = ''
            Bucket "${b.name}" has clamped replication factor ${toString b._clampedRF}.
            The cluster has 0 zones with non-zero capacity; buckets must have RF >= 1.
          '';
        }) (lib.attrValues clampedBuckets)
        ++ map (b: {
          assertion = b._intendedRF == b._clampedRF;
          message = ''
            Bucket "${b.name}" requested replicationFactor = ${toString b._intendedRF}
            but the cluster only has ${toString numZonesWithCapacity} zone(s)
            with non-zero capacity. RF clamped to ${toString b._clampedRF}.

            To silence this warning, either:
              - Lower the bucket's replicationFactor to ${toString b._clampedRF}, or
              - Add more zones with capacity to cluster.layout.zones.

            Clamping is intentional: Garage will only keep
            ${toString b._clampedRF} copy/copies of objects in this bucket.
          '';
        }) (lib.filter (b: b._intendedRF != b._clampedRF) (lib.attrValues clampedBuckets));
    }
  ]);
}
