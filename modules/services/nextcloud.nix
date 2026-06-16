# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/nextcloud — Nextcloud with native S3 primary storage
# pointed at a Garage bucket.
#
# Contract (per AGENTS.md "Service Modules"):
#   enable    — opt-in toggle
#   domain    — external FQDN for the Caddy vhost
#   public    — true → Caddy reverse-proxies; false → 403
#   bucket    — name of the Garage bucket used as primary storage
#
# The S3 credentials come from the cococoir/garage clan-service's
# `garage-global-s3-key` clan-core var. Before evaluation, run
# `clan vars generate` (or `clan machines update`) on the target machine
# to produce the var files.
{ config, lib, ... }:
let
  cfg = config.cococoir.services.nextcloud;
  bucket = config.cococoir.storage.derived.buckets.${cfg.bucket} or null;
  s3KeyPath = config.clan.core.vars.generators.garage-global-s3-key.files.access-key-id.path;
  s3SecretPath = config.clan.core.vars.generators.garage-global-s3-key.files.secret-access-key.path;
in
{
  options.cococoir.services.nextcloud = {
    enable = lib.mkEnableOption "Nextcloud (S3-backed primary storage)";
    domain = lib.mkOption {
      type = lib.types.str;
      description = "External FQDN for the Caddy vhost (e.g. cloud.example.com).";
    };
    public = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to allow public access.";
    };
    bucket = lib.mkOption {
      type = lib.types.str;
      description = "Name of the Garage bucket used as primary storage.";
    };
  };

  config = lib.mkIf (cfg.enable && bucket != null) {
    services.nextcloud = {
      enable = true;
      hostName = cfg.domain;
      database.createLocally = true;
      https = false;
      config = {
        dbtype = "pgsql";
        adminpassFile = config.clan.core.vars.generators.nextcloud-admin-pass.files.admin-pass.path;
        objectstore.s3 = {
          enable = true;
          bucket = cfg.bucket;
          hostname = bucket.host;
          port = bucket.port;
          region = bucket.region;
          key = builtins.readFile s3KeyPath;
          secretFile = s3SecretPath;
          useSsl = false;
          usePathStyle = true;
          verify_bucket_exists = false;
        };
        trusted_domains = [ cfg.domain ];
      };
    };

    services.caddy.virtualHosts."${cfg.domain}".extraConfig =
      if cfg.public
      then "reverse_proxy localhost:80"
      else ''respond "Forbidden" 403'';

    clan.core.vars.generators.nextcloud-admin-pass = {
      files.admin-pass = { };
      script = "openssl rand -base64 -out \"$out/admin-pass\" 32";
    };
  };
}
