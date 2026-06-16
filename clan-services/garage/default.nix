# SPDX-License-Identifier: AGPL-3.0-or-later
#
# clan.service module: cococoir/garage
#
# Single-node primary path. Multi-node is a future exercise — see
# AGENTS.md "Storage" for the design notes.
#
# Provides:
#   - Static `garage` system user + persistent data/meta dirs
#   - Optional inline disko provisioning of a dedicated data drive
#     (or use `cococoir.lib.mkGarageDataDisko` in the machine's
#     disko.nix for custom layouts)
#   - nixpkgs services.garage, hardened (LoadCredential + env vars,
#     DynamicUser disabled, data dir owned by the static user)
#   - Clan vars for rpc-secret (shared), admin-token, metrics-token
#   - bucket-init oneshot: idempotent first-boot setup of the global
#     S3 key, single-node layout, and per-bucket config. Script lives
#     in ./bucket-init.sh; Nix just generates a buckets.json config.
#   - FUSE mounts via `fileSystems.<path>.fsType = "fuse.geesefs"` —
#     NixOS generates the mount units, we add After/Requires on the
#     bucket-init service.
#   - cococoir.storage.derived.{gatewayAddress,buckets.<n>.{endpoint,
#     accessKeyIdFile,secretAccessKeyFile}} for native-S3 clients
{ lib, ... }:
let
  bucketSubmodule = { ... }: {
    options.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to create this bucket on first boot.";
    };
    options.quotas = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional storage quota (e.g. \"100G\").";
    };
    options.website = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable static-website hosting for this bucket.";
    };
  };

  mountSubmodule = { ... }: {
    options.bucket = lib.mkOption {
      type = lib.types.str;
      description = "Name of the bucket to mount.";
    };
    options.mountPoint = lib.mkOption {
      type = lib.types.str;
      description = "Local filesystem path to mount the bucket at.";
    };
    options.readOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
in
{
  _class = "clan.service";
  manifest.name = "cococoir/garage";
  manifest.description = "S3-compatible object store with bucket automation and FUSE mounts (single-node primary).";
  manifest.categories = [ "System" ];

  roles.node = {
    description = "A single garage node providing S3 storage";
    interface = { lib, ... }: {
      options.address = lib.mkOption {
        type = lib.types.str;
        example = "10.0.0.2:3901";
        description = ''
          This node's RPC bind address. For multi-node, peers are
          auto-derived from other machines' `address` settings.
        '';
      };
      options.capacity = lib.mkOption {
        type = lib.types.str;
        default = "1T";
        description = ''
          Storage capacity this node contributes to its zone. Used for
          RF clamping and capacity reporting in the bucket-init oneshot.
        '';
      };
      options.dataDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/disk/by-id/wwn-0x5000c500...";
        description = ''
          Optional: a block device to provision as a dedicated data drive
          via disko. If null, the data dir is expected to exist (or
          `cococoir.lib.mkGarageDataDisko` is used in the machine's
          disko.nix for custom layouts).
        '';
      };
      options.buckets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule bucketSubmodule);
        default = { };
        description = "Buckets to create on first boot.";
      };
      options.mounts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule mountSubmodule);
        default = { };
        description = "FUSE mounts (geesefs) exposing buckets as local filesystems.";
      };
    };

    perInstance =
      { instanceName, settings, ... }:
      let
        me = settings;
        dataDir = "/var/lib/cococoir/garage/data";
        metaDir = "/var/lib/cococoir/garage/meta";
        globalDir = "/var/lib/cococoir/garage/global";
        s3ApiPort = 3900;
        rpcPort = 3901;
        adminPort = 3903;
        region = "garage";
      in
      {
        nixosModule =
          { config, pkgs, lib, ... }:
          let
            bucketInitJson = pkgs.writeText "garage-buckets.json" (builtins.toJSON {
              inherit (me) address capacity;
              zone = instanceName;
              buckets = lib.mapAttrs (_: b: {
                inherit (b) enable quotas website;
              }) me.buckets;
            });
          in
          {
            assertions = [
              {
                assertion = me ? address;
                message = "cococoir/garage: `address` is required (e.g. \"10.0.0.2:3901\").";
              }
            ];

            config = {
              # Static system user (DynamicUser disabled because data dir
              # ownership must be stable across restarts).
              users.users.garage = {
                isSystemUser = true;
                group = "garage";
                home = metaDir;
                createHome = true;
              };
              users.groups.garage = { };

              # Ensure data + meta + global-key dirs exist with the right
              # ownership.
              systemd.tmpfiles.rules = [
                "d ${dataDir} 0750 garage garage - -"
                "d ${metaDir} 0750 garage garage - -"
                "d ${globalDir} 0700 garage garage - -"
              ];

              # Optional inline disko provisioning of the data drive.
              disko = lib.mkIf (me.dataDevice != null) {
                devices.disk."cococoir-garage-data" = {
                  device = me.dataDevice;
                  type = "disk";
                  content = {
                    type = "gpt";
                    partitions.primary = {
                      size = "100%";
                      content = {
                        type = "filesystem";
                        format = "xfs";
                        mountpoint = dataDir;
                      };
                    };
                  };
                };
              };

              # nixpkgs services.garage, with secrets loaded from
              # LoadCredential= (no placeholder+sed hack).
              services.garage = {
                enable = true;
                dataDir = dataDir;
                metaDir = metaDir;
                package = pkgs.garage;
                settings = {
                  replication_factor = 1;
                  rpc_bind_addr = "0.0.0.0:${toString rpcPort}";
                  rpc_public_addr = me.address;
                  s3_api.bind_addr = "127.0.0.1:${toString s3ApiPort}";
                  admin.bind_addr = "127.0.0.1:${toString adminPort}";
                  s3_api.root_domain = "s3.${region}.local";
                };
              };

              # Systemd services: garage (with hardened LoadCredential +
              # static user), bucket-init (oneshot first-boot setup), and
              # FUSE mount units (After/Requires on bucket-init).
              systemd.services = {
                garage.serviceConfig = {
                  DynamicUser = lib.mkForce false;
                  User = "garage";
                  Group = "garage";
                  LoadCredential = [
                    "rpc_secret:${config.clan.core.vars.generators.garage-rpc-secret.files.rpc-secret.path}"
                    "admin_token:${config.clan.core.vars.generators.garage-admin-token.files.admin-token.path}"
                    "metrics_token:${config.clan.core.vars.generators.garage-metrics-token.files.metrics-token.path}"
                  ];
                  Environment = [
                    "GARAGE_ALLOW_WORLD_READABLE_SECRETS=true"
                    "GARAGE_RPC_SECRET_FILE=%d/rpc_secret"
                    "GARAGE_ADMIN_TOKEN_FILE=%d/admin_token"
                    "GARAGE_METRICS_TOKEN_FILE=%d/metrics_token"
                  ];
                };
                garage-bucket-init = {
                  description = "cococoir/garage bucket init: global S3 key, layout, buckets";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "garage.service" ];
                  requires = [ "garage.service" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    User = "garage";
                    Group = "garage";
                    WorkingDirectory = metaDir;
                    ExecStart = "${./bucket-init.sh} ${bucketInitJson} ${globalDir}";
                    Environment = [
                      "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.garage pkgs.jq pkgs.gnused pkgs.gawk ]}"
                      "CLAN_VAR_S3_KEY_DIR=${config.clan.core.vars.generators.garage-global-s3-key.files.access-key-id.path | lib.dirOf}"
                    ];
                  };
                };
              }
              // (lib.mapAttrs' (_: m: {
                name = "${lib.replaceStrings [ "/" ] [ "-" ] m.mountPoint}.mount";
                value = {
                  after = [ "garage-bucket-init.service" ];
                  requires = [ "garage-bucket-init.service" ];
                };
              }) me.mounts);

              # Clan vars: rpc-secret and the global S3 key are shared
              # (cluster-wide); admin and metrics tokens are per-node.
              # The S3 key is pre-generated so native-S3 clients with
              # eval-time configs (Nextcloud's objectstore.s3) can read it.
              # bucket-init.sh imports it into garage on first boot.
              clan.core.vars.generators.garage-rpc-secret = {
                share = true;
                files.rpc-secret = { };
                runtimeInputs = [ pkgs.coreutils pkgs.openssl ];
                script = "openssl rand -hex -out \"$out/rpc-secret\" 32";
              };
              clan.core.vars.generators.garage-global-s3-key = {
                share = true;
                files.access-key-id = { };
                files.secret-access-key = { };
                runtimeInputs = [ pkgs.coreutils pkgs.openssl ];
                script = ''
                  printf 'GK%s' "$(openssl rand -hex 20)" > "$out/access-key-id"
                  openssl rand -base64 -out "$out/secret-access-key" 32
                '';
              };
              clan.core.vars.generators.garage-admin-token = {
                files.admin-token = { };
                runtimeInputs = [ pkgs.coreutils pkgs.openssl ];
                script = "openssl rand -base64 -out \"$out/admin-token\" 32";
              };
              clan.core.vars.generators.garage-metrics-token = {
                files.metrics-token = { };
                runtimeInputs = [ pkgs.coreutils pkgs.openssl ];
                script = "openssl rand -base64 -out \"$out/metrics-token\" 32";
              };

              # Make sure the geesefs binary is on PATH for the FUSE mount.
              environment.systemPackages = [ pkgs.geesefs ];

              # FUSE mounts: declarative fileSystems, NixOS generates the
              # mount units. The After/Requires on bucket-init is set in
              # the systemd.services.<mount>.mount override above.
              fileSystems = lib.mapAttrs' (_: m: {
                name = m.mountPoint;
                value = {
                  device = m.bucket;
                  fsType = "fuse.geesefs";
                  options = [
                    "allow_other"
                    "default_permissions"
                    "use_path_request_style"
                    "url=http://127.0.0.1:${toString s3ApiPort}"
                    "region=${region}"
                  ] ++ lib.optional m.readOnly "ro";
                };
              }) me.mounts;

              # Derived config: what native-S3 and FUSE consumers read.
              cococoir.storage.derived.gatewayAddress = "127.0.0.1:${toString s3ApiPort}";
              cococoir.storage.derived.buckets = lib.mapAttrs (n: b: {
                name = n;
                endpoint = "http://127.0.0.1:${toString s3ApiPort}";
                host = "127.0.0.1";
                port = s3ApiPort;
                region = region;
                accessKeyIdFile = config.clan.core.vars.generators.garage-global-s3-key.files.access-key-id.path;
                secretAccessKeyFile = config.clan.core.vars.generators.garage-global-s3-key.files.secret-access-key.path;
              }) me.buckets;
              # Mounts are keyed by bucket name (not mount name) so service
              # modules that reference a bucket can resolve the mount point
              # with `derived.mounts.${cfg.bucket}.mountPoint`. If the same
              # bucket is mounted twice, the last declaration wins.
              cococoir.storage.derived.mounts = lib.mapAttrs' (_: m: {
                name = m.bucket;
                value = {
                  mountPoint = m.mountPoint;
                  readOnly = m.readOnly;
                };
              }) me.mounts;
            };
          };
      };
  };
}
