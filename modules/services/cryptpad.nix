# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/cryptpad — CryptPad collaborative office suite with
# its dataPath backed by a FUSE-mounted Garage bucket.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → localNetworks 403
#   bucket    — name of the Garage bucket (default "cryptpad-data",
#               override only to share a bucket with another service)
#
# Enabling this service auto-declares its bucket + FUSE mount in
# `cococoir.storage.*`, so the user does not need to wire up
# storage separately. The cococoir/garage clan-service consumes
# those declarations.
{
  config,
  lib,
  ...
}: let
  cfg = config.cococoir.services.cryptpad;
  defaultBucket = "cryptpad-data";
  defaultMount = "/var/lib/cococoir/cryptpad";
  mount = config.cococoir.storage.derived.mounts.${cfg.bucket};
in {
  options.cococoir.services.cryptpad = {
    enable = lib.mkEnableOption "CryptPad collaborative office suite";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External FQDN for CryptPad (e.g. pad.example.com).";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to allow public access to CryptPad.";
    };

    bucket = lib.mkOption {
      type = lib.types.str;
      default = defaultBucket;
      description = ''
        Name of the Garage bucket that backs the CryptPad dataPath.
        Defaults to "${defaultBucket}"; override only to share a
        bucket with another service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    cococoir.storage.buckets.${cfg.bucket} = { };
    cococoir.storage.mounts.${cfg.bucket} = {
      bucket = cfg.bucket;
      mountPoint = defaultMount;
    };

    services.cryptpad = {
      enable = true;
      settings = {
        httpAddress = "127.0.0.1";
        httpPort = 9123;
        httpUnsafeOrigin = "https://${cfg.domain}";
        httpSafeOrigin = "https://${cfg.domain}";
        filePath = mount.mountPoint;
        blockDailyCheck = true;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${mount.mountPoint} 0750 cryptpad cryptpad - -"
    ];

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then ''reverse_proxy localhost:9123''
      else ''
        @not_local not remote_ip ${lib.concatStringsSep " " config.cococoir.localNetworks}
        respond @not_local "Forbidden" 403
        reverse_proxy localhost:9123
      '';
  };
}
