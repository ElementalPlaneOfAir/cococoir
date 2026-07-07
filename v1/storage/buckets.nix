# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/storage — NixOS-level options that bridge service modules and
# the cococoir/garage clan-service.
#
# Why this layer exists
# ──────────────────────
# Service modules (cryptpad, jellyfin, qBittorrent) own their own storage:
#   - which Garage bucket to use (a hardcoded default per service)
#   - where the FUSE mount lives (a hardcoded path per service)
#   - which subdirectory is the data dir (derived from the mount point)
#
# The user should not have to know that "cryptpad" maps to a bucket
# called "cryptpad-data" mounted at "/var/lib/cococoir/cryptpad" —
# they just enable the service. To make that work, every service
# module writes its bucket + mount to these options, and the
# cococoir/garage clan-service reads them in its perInstance closure
# to drive bucket-init.sh and the FUSE mount units.
#
# Overriding
# ──────────
# The defaults are right for 99% of users. To share a bucket between
# two services (e.g. jellyfin and qBittorrent both using "media"),
# set the `bucket` option on both services to the same name — the
# service modules will each add a bucket entry, which attrset-merges
# to a single declaration. To mount a bucket at multiple points, set
# `mounts.<name>.mountPoint` directly.
#
# Note: this module does not own the cluster (rpc-secret, node
# identity, layout). Those live in `clan.services.cococoir-garage`
# role options, exposed via `flake.nixosModules.cococoir-garage`.
{
  lib,
  ...
}: {
  options.cococoir.storage = {
    buckets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { });
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
        Read-only resolved view written by the cococoir/garage
        clan-service after evaluating the cluster. Service modules
        consume this (e.g. cryptpad reads
        `derived.mounts.<bucket>.mountPoint`, nextcloud reads
        `derived.buckets.<bucket>.{endpoint,region,…}`).

        Do not set these from a service module — they are produced
        by garage, not consumed by it.
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
