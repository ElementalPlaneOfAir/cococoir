# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/cryptpad — CryptPad collaborative office suite.
#
# 4-option contract (per PLAN.md "Services" + ADR-004):
#   enable  — opt-in toggle
#   domain  — external FQDN for the Caddy vhost
#   public  — true → Caddy reverse-proxies; false → 403
#   bucket  — Garage bucket that backs cryptpad's data
#
# CryptPad needs TWO origins: httpUnsafeOrigin (main) and
# httpSafeOrigin (sandbox for CSP isolation). We serve both from
# the same domain to keep the contract simple — the sandbox
# protection is weakened but acceptable for a homelab setup.
# Adding a separate sandbox subdomain (cryptpad-sandbox.<domain>)
# is a future enhancement if strict CSP isolation is required.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  mkCococoirService = import ./_contract.nix {inherit lib config pkgs options;};
in
mkCococoirService {
  name = "cryptpad";
  description = "CryptPad collaborative office suite";
  defaultPort = 3000;
  defaultBucket = "cryptpad-data";
  defaultMount = "/var/lib/cococoir/cryptpad";
  extraConfig = {cfg, lib, pkgs, ...}: {
    services.cryptpad = {
      enable = true;
      configureNginx = false;
      settings = {
        httpAddress = "127.0.0.1";
        httpPort = cfg.port;
        httpUnsafeOrigin = "https://${cfg.domain}";
        httpSafeOrigin = "https://${cfg.domain}";
        filePath = "/var/lib/cococoir/cryptpad";
        blockDailyCheck = true;
        logToStdout = true;
        installMethod = "cococoir";
      };
    };

    systemd.services.cryptpad = {
      after = ["cococoir-fuse-${cfg.bucket}.service"];
      serviceConfig = {
        BindPaths = ["-/var/lib/cococoir/cryptpad"];
      };
    };

    cococoir.storage.buckets.${cfg.bucket}.replicationFactor = 1;
    cococoir.storage.mounts.${cfg.bucket} = {
      bucket = cfg.bucket;
      mountPoint = "/var/lib/cococoir/cryptpad";
    };
  };
}
