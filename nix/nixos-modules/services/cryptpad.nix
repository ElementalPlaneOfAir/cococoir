# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/services/cryptpad — CryptPad collaborative office suite.
#
# 4-option contract (per PLAN.md "Services" + ADR-004):
#   enable  — opt-in toggle
#   domain  — external FQDN for the Caddy vhost
#   public  — true → Caddy reverse-proxies; false → 403
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

  cryptpadSSO = pkgs.fetchFromGitHub {
    owner = "cryptpad";
    repo = "sso";
    rev = "4f77fca4a9e937fbbc7c189da41fc126133c641a";
    sha256 = "16sr3n9ffay9i04i9c7kng3bk1pkmv2gyrqc1q9a26jsf5ryhawp";
  };

  cryptpad-with-sso = pkgs.runCommand "cryptpad-with-sso-${pkgs.cryptpad.version}" {
    nativeBuildInputs = [ pkgs.rsync pkgs.gnused ];
    meta.mainProgram = "cryptpad";
  } ''
    rsync -a ${pkgs.cryptpad}/ $out/
    chmod -R u+w $out
    mkdir -p $out/lib/node_modules/cryptpad/lib/plugins/SSO
    cp -r ${cryptpadSSO}/* $out/lib/node_modules/cryptpad/lib/plugins/SSO/
    sed -i "s|${pkgs.cryptpad}|$out|g" $out/bin/cryptpad
  '';
in
mkCococoirService {
  name = "cryptpad";
  description = "CryptPad collaborative office suite";
  defaultPort = 3000;
  defaultHealthPath = "/checkup/";
  storageNeeded = true;
  extraConfig = {cfg, lib, pkgs, config, ...}: let
    dataRoot = config.cococoir.storage.btrfs.pool.mountpoint;
    cryptpadDataPath = "${dataRoot}/cryptpad/data";
  in {
    users.users.cococoir-cryptpad = {
      isSystemUser = true;
      group = "cococoir-cryptpad";
      description = "CryptPad service user";
    };
    users.groups.cococoir-cryptpad = {};

    services.cryptpad = {
      enable = true;
      package = cryptpad-with-sso;
      configureNginx = false;
      settings = {
        httpAddress = "127.0.0.1";
        httpPort = cfg.port;
        httpUnsafeOrigin = "https://${cfg.domain}";
        httpSafeOrigin = "https://${cfg.domain}";
        filePath = cryptpadDataPath;
        blockDailyCheck = true;
        logToStdout = true;
        installMethod = "cococoir";
      };
    };

    systemd.services.cryptpad = {
      after = ["cococoir-btrfs-subvolumes.service"];
      requires = ["cococoir-btrfs-subvolumes.service"];
      unitConfig.RequiresMountsFor = cryptpadDataPath;
      confinement.enable = lib.mkForce false;
      serviceConfig = {
        # The subvolume is chowned to cococoir-cryptpad by the btrfs
        # module, so the service needs a stable user rather than the
        # DynamicUser the nixpkgs module defaults to.
        DynamicUser = lib.mkForce false;
        User = "cococoir-cryptpad";
        Group = "cococoir-cryptpad";
        ReadWritePaths = [cryptpadDataPath];
      };
      # cryptpad first-boot bug: on an empty decree file, api.js
      # writes SET_BEARER_SECRET but never applies it to the running
      # Env (workers fork before Decrees.load; write is append-only).
      # SSO/JWT signing then fails with "secretOrPrivateKey must have
      # a value" until the next restart. Seed the decree before start
      # so Decrees.load replays it on first boot.
      serviceConfig.ExecStartPre = lib.mkAfter [
        (pkgs.writeShellScript "cococoir-cryptpad-seed-bearer" ''
          set -euo pipefail
          DECREE="''${STATE_DIRECTORY:-}/data/decree.ndjson"
          if [ -z "$DECREE" ]; then
            echo "cococoir-cryptpad-seed-bearer: \$STATE_DIRECTORY unset" >&2
            exit 1
          fi
          if [ ! -f "$DECREE" ] || ! grep -q SET_BEARER_SECRET "$DECREE"; then
            mkdir -p "$(dirname "$DECREE")"
            SECRET="$(${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '\n')"
            printf '["SET_BEARER_SECRET",["%s"],"INTERNAL",%s]\n' "$SECRET" "$(date +%s%3N)" >> "$DECREE"
          fi
        '')
      ];
    };

    cococoir.storage.btrfs.subvolumes."cryptpad-data" = {
      mountpoint = lib.mkDefault cryptpadDataPath;
      quota = "100G";
      owner = {
        user = "cococoir-cryptpad";
        mode = "700";
      };
    };
  };
}
