# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/cryptpad — CryptPad collaborative office suite with
# its dataPath backed by a FUSE-mounted Garage bucket.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → localNetworks 403
#   bucket    — name of the Garage bucket that backs the dataPath
#
# FUSE mounts are owned by the cococoir/garage clan-service. The CryptPad
# module asserts that a mount exists for the referenced bucket and
# resolves the dataPath from `cococoir.storage.derived.mounts`. If the
# bucket has no mount, evaluation fails with a clear error.
{
  config,
  lib,
  ...
}: let
  cfg = config.cococoir.services.cryptpad;
  mount = config.cococoir.storage.derived.mounts.${cfg.bucket} or null;
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
      description = ''
        Name of the Garage bucket that backs the CryptPad dataPath. A
        FUSE mount for this bucket must be declared in the
        cococoir/garage clan-service's `mounts.<name>`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mount != null;
        message = ''
          cococoir/services/cryptpad: bucket "${cfg.bucket}" has no FUSE
          mount declared in the cococoir/garage clan-service. Add an
          entry to `roles.<role>.machines.<name>.settings.mounts`:
            mounts.<name> = {
              bucket = "${cfg.bucket}";
              mountPoint = "/var/lib/cryptpad";
            };
        '';
      }
    ];

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
