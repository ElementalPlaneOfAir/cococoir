# SPDX-License-Identifier: AGPL-3.0-or-later
#
# clan.service module: cococoir/garage
#
# Owns the cluster (rpc secret, node identity, layout, garage daemon)
# and reads bucket + FUSE-mount declarations from `cococoir.storage.*`
# (which service modules fill in automatically). Users do not declare
# buckets or mounts directly — enabling a service that needs storage
# is sufficient.
#
# Provides:
#   - Static `garage` system user + persistent data/meta dirs
#   - nixpkgs services.garage, hardened (LoadCredential + env vars,
#     DynamicUser disabled, data dir owned by the static user)
#   - Clan vars for rpc-secret (shared), admin-token, metrics-token,
#     and the pre-generated global S3 key (shared, imported by
#     bucket-init.sh so native-S3 clients can read it at eval time)
#   - bucket-init oneshot: idempotent first-boot setup of the cluster
#     layout, buckets, and access-key import. Script lives in
#     ./bucket-init.sh; Nix just generates a buckets.json config
#     from `config.cococoir.storage.buckets`.
#   - FUSE mounts via `fileSystems.<path>.fsType = "fuse.geesefs"` —
#     NixOS generates the mount units, we add After/Requires on the
#     bucket-init service.
#   - cococoir.storage.derived.{gatewayAddress,buckets.<n>.{endpoint,
#     accessKeyIdFile,secretAccessKeyFile},mounts.<bucket>} for
#     native-S3 clients and service modules.
#
# Cluster-level data (address, capacity) is configured on the role;
# bucket + mount data is configured by service modules at the NixOS
# level (see cococoir/storage/buckets.nix).
{ lib, ... }: let
  # Returns true when `mp` is a subdirectory of another declared
  # fileSystem (excluding itself). Used to add After= on the parent
  # mount so the FUSE mount waits for the parent to come up.
  hasParentMount = fileSystems: mp:
    let
      parent = builtins.dirOf mp;
    in
    parent != "/" && parent != "." && fileSystems ? ${parent};

  # Unit name of the parent mount, with the same escaping NixOS uses
  # for the fileSystems attrset (every "/" becomes "-", and a leading
  # "/" becomes a leading "-").
  parentMountUnit = mp: let
    parent = builtins.dirOf mp;
  in "${lib.replaceStrings [ "/" ] [ "-" ] parent}.mount";
in {
  _class = "clan.service";
  manifest.name = "cococoir/garage";
  manifest.description = "S3-compatible object store with bucket automation and FUSE mounts.";
  manifest.categories = [ "System" ];
  manifest.readme = builtins.readFile ./README.md;

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
          capacity reporting in the bucket-init oneshot.
        '';
      };
    };

    perInstance =
      {
        instanceName,
        settings,
        ...
      }:
      let
        me = settings;
      in
      {
        nixosModule =
          { config, pkgs, lib, ... }:
          let
            dataDir = "/var/lib/cococoir/garage/data";
            metaDir = "/var/lib/cococoir/garage/meta";
            globalDir = "/var/lib/cococoir/garage/global";
            s3ApiPort = 3900;
            rpcPort = 3901;
            adminPort = 3903;
            region = "garage";
            bucketNames = builtins.attrNames config.cococoir.storage.buckets;
            mountNames = builtins.attrNames config.cococoir.storage.mounts;
            s3KeyDir = lib.dirOf config.clan.core.vars.generators.garage-global-s3-key.files.access-key-id.path;
            bucketInitJson = pkgs.writeText "garage-buckets.json" (builtins.toJSON {
              inherit (me) address capacity;
              zone = instanceName;
              buckets = bucketNames;
            });
          in {
            assertions = [
              {
                assertion = me ? address;
                message = "cococoir/garage: `address` is required (e.g. \"10.0.0.2:3901\").";
              }
              {
                assertion = bucketNames != [ ];
                message = ''
                  cococoir/garage: no buckets declared. Enable a cococoir
                  service that needs storage (e.g. jellyfin, qBittorrent,
                  cryptpad) or set cococoir.storage.buckets directly.
                '';
              }
              {
                # Every mount must reference a declared bucket.
                assertion = lib.all (m: builtins.elem config.cococoir.storage.mounts.${m}.bucket bucketNames) mountNames;
                message = let
                  orphans = lib.filter (m: !(builtins.elem config.cococoir.storage.mounts.${m}.bucket bucketNames)) mountNames;
                in ''
                  cococoir/garage: mount(s) reference undeclared bucket(s):
                  ${lib.concatStringsSep ", " (map (m: ''
                    ${m} → "${config.cococoir.storage.mounts.${m}.bucket}"
                  '') orphans)}
                  Declare the bucket via a service that uses it, or add it
                  to cococoir.storage.buckets.
                '';
              }
            ];

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

            # nixpkgs services.garage, with secrets loaded from
            # LoadCredential= (no placeholder+sed hack).
            services.garage = {
              enable = true;
              package = pkgs.garage;
              settings = {
                replication_factor = 1;
                data_dir = dataDir;
                metadata_dir = metaDir;
                rpc_bind_addr = "0.0.0.0:${toString rpcPort}";
                rpc_public_addr = me.address;
                s3_api.bind_addr = "127.0.0.1:${toString s3ApiPort}";
                s3_api.s3_region = region;
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
                    "PATH=${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.garage pkgs.jq pkgs.gnused pkgs.gawk ]}"
                    "CLAN_VAR_S3_KEY_DIR=${s3KeyDir}"
                  ];
                };
              };
            }
            // (lib.mapAttrs' (_: m: {
              name = "${lib.replaceStrings [ "/" ] [ "-" ] m.mountPoint}.mount";
              value = {
                # Wants, not Requires: the mount should wait for
                # bucket-init (so the bucket + key exist before FUSE
                # connects) but must not block local-fs.target if
                # bucket-init is delayed. local-fs.target transitively
                # pulls garage.service (via Requires= on
                # garage-bucket-init), which lives in multi-user.target
                # — a hard Requires on the FUSE mount would create a
                # cycle that drops the system to emergency mode when
                # garage is slow to start. With Wants, the mount is
                # attempted after bucket-init comes up; if it fails
                # (e.g. garage not running), the nofail mount option
                # keeps boot moving.
                #
                # If the mount point is a subdirectory of another
                # declared fileSystem (e.g. /media/entertain is under
                # /media), we also After= that parent mount so the
                # parent comes up first. Without this, the FUSE mount
                # races the parent and fails to find its mount point
                # directory at boot. The parent is a normal mount
                # (btrfs / ext4 / etc.), so adding After= to it
                # doesn't introduce a multi-user.target cycle.
                #
                # NixOS's fstab generator doesn't set Environment=PATH
                # for auto-generated mount units, so `mount -t
                # fuse.geesefs` ends up running with systemd's default
                # minimal PATH and can't find `geesefs` in
                # /run/current-system/sw/bin. Set PATH explicitly so
                # mount.fuse3 can exec the FUSE helper. NixOS's systemd
                # module also defines a default PATH for mount units
                # (system paths), but it's merged with this one at
                # eval time and causes a conflict — so mkForce the
                # union of system paths + geesefs.
                environment.PATH = lib.mkForce (lib.makeBinPath ([
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.systemd
                ] ++ [ pkgs.geesefs ]));
                after =
                  [ "garage-bucket-init.service" ]
                  ++ lib.optional (hasParentMount config.fileSystems m.mountPoint) "${parentMountUnit m.mountPoint}";
                wants = [ "garage-bucket-init.service" ];
              };
            }) config.cococoir.storage.mounts);

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
            # mount units. The `nofail` option is critical for boot
            # safety: the mount unit is in local-fs.target, which
            # transitively depends on garage.service (via the
            # garage-bucket-init → garage chain). If garage is slow or
            # broken at boot, the FUSE mount would block local-fs.target
            # and drop the system to emergency mode. With `nofail`, the
            # mount is best-effort at boot and is re-attempted on
            # later activations (e.g. after a manual
            # `systemctl start garage`).
            fileSystems = lib.mapAttrs' (_: m: {
              name = m.mountPoint;
              value = {
                device = m.bucket;
                fsType = "fuse.geesefs";
                options = [
                  "nofail"
                  "allow_other"
                  "default_permissions"
                  "use_path_request_style"
                  "url=http://127.0.0.1:${toString s3ApiPort}"
                  "region=${region}"
                ] ++ lib.optional m.readOnly "ro";
              };
            }) config.cococoir.storage.mounts;

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
            }) config.cococoir.storage.buckets;
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
            }) config.cococoir.storage.mounts;
          };
      };
  };
}
