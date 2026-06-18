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
#     ./bucket-init.sh; per-instance values (address, zone, capacity,
#     bucket names) are passed as positional args, not a generated JSON
#     file. The S3 access key is read directly from a file at
#     $CLAN_VAR_S3_KEY_DIR (a SOPS-decrypted clan-core var) — no JSON
#     round-trip.
#   - FUSE mounts via per-mount systemd services (lxcfs.nix pattern),
#     not `fileSystems` with `fuse.<path>` (which is broken — see
#     NixOS/nixpkgs#21748).
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

            # Per-mount FUSE service, modelled on
            # nixpkgs/nixos/modules/virtualisation/lxcfs.nix (the
            # canonical NixOS FUSE pattern, also recommended for
            # s3fs in the NixOS Discourse thread "How to setup
            # s3fs mount", post #2).
            #
            # Why a service, not `fileSystems` with
            # `fuse.<path-to-binary>`? `mount` deliberately strips
            # PATH before invoking FUSE helpers via
            # `/bin/sh -c '<binary> ...'`, and NixOS's /bin/sh
            # (bash) has `/no-such-path` compiled in as its default
            # PATH (pkgs/shells/bash/4.4.nix#L46). So
            # `fsType = "fuse.geesefs"` and even
            # `fsType = "fuse.${pkgs.geesefs}/bin/geesefs"` silently
            # fail at boot with `geesefs: command not found`. See
            # NixOS/nixpkgs#21748 and the NixOS Discourse thread
            # #6283 for the long history. The symlink form
            # `fuse./run/current-system/sw/bin/<name>` works
            # (post #5-6) but requires the package in
            # environment.systemPackages and is fragile. The
            # service approach avoids both issues by invoking the
            # binary by absolute path with no shell involved —
            # `${pkgs.geesefs}/bin/geesefs` is in the system
            # closure, so the path is stable across rebuilds.
            #
            # `wantedBy = multi-user.target` (NOT local-fs.target)
            # because the FUSE service is a service unit, not a
            # mount unit — local-fs.target is for fileSystems.
            # Keeping the FUSE service out of local-fs.target means
            # boot is not blocked if garage is down: the FUSE
            # service keeps retrying (Restart=on-failure,
            # RestartSec=10s), and consumer services that
            # `After=[cococoir-fuse-<bucket>.service]` will also be
            # delayed, but local-fs.target and the rest of the
            # system come up. The user can boot into a working
            # system even if garage is broken, then debug garage.
            #
            # `after = [garage-bucket-init.service]`: the bucket +
            # global S3 key must exist in garage before FUSE
            # connects. The bucket-init service is already a
            # one-shot after garage.service, so by transitive
            # ordering through multi-user.target this also
            # implicitly waits for garage.
            #
            # `+ lib.optional parentMount`: if the mount point is a
            # subdirectory of another declared fileSystem (e.g.
            # /media/entertain under /media), we also wait for the
            # parent mount. Otherwise the FUSE service races the
            # parent and fails to find its mount point directory.
            # The parent is a normal fileSystem in local-fs.target,
            # so After= on it is safe.
            #
            # `requires` (not `wants`) on bucket-init: the FUSE
            # mount needs the bucket to exist in garage before
            # geesefs can connect. `requires` makes the FUSE
            # service wait until bucket-init is `active` — and
            # for a `Type=oneshot, RemainAfterExit=true` unit,
            # `active` means "exited with success", which is
            # exactly the "bucket is ready" condition we want.
            # If bucket-init fails permanently, FUSE fails too;
            # both will be visible in `systemctl --failed`.
            #
            # `serviceConfig` notes:
            #   - `Type = simple`: the service is "active" while
            #     geesefs is running. The kernel registers the
            #     FUSE mount on the process's behalf.
            #   - `ExecStartPre = mkdir -p`: ensure the mount
            #     point dir exists before geesefs tries to mount
            #     there. Cheap, idempotent.
            #   - `ExecStart`: the FUSE binary in foreground mode.
            #     No `-f` flag because geesefs's default mode is
            #     foreground.
            #   - `ExecStopPost = fusermount3 -u`: cleanly unmount
            #     on stop. The `-` prefix means "ignore exit code"
            #     — the unmount may fail if the FS is already gone
            #     (e.g. crash), which is fine.
            #   - `KillMode = process`: only kill the main process,
            #     not children, so fusermount3 can do its job on
            #     stop.
            #   - `Restart = on-failure` + `RestartSec = 10s`: FUSE
            #     can drop on S3 transient errors. Restarting
            #     re-establishes the mount.
            fuseServices = lib.mapAttrs' (name: m: {
              name = "cococoir-fuse-${name}";
              value = {
                description = "FUSE mount of Garage bucket '${m.bucket}' to ${m.mountPoint}";
                wantedBy = [ "multi-user.target" ];
                after =
                  [ "garage-bucket-init.service" ]
                  ++ lib.optional (hasParentMount config.fileSystems m.mountPoint) "${parentMountUnit m.mountPoint}";
                requires = [ "garage-bucket-init.service" ];
                serviceConfig = {
                  Type = "simple";
                  ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${m.mountPoint}";
                  ExecStart = lib.concatMapStringsSep " " (s: lib.escapeShellArg s) [
                    "${pkgs.geesefs}/bin/geesefs"
                    m.bucket
                    m.mountPoint
                    "-o"
                    (lib.concatStringsSep "," ([
                      "allow_other"
                      "default_permissions"
                      "use_path_request_style"
                      "url=http://127.0.0.1:${toString s3ApiPort}"
                      "region=${region}"
                    ] ++ lib.optional m.readOnly "ro"))
                  ];
                  ExecStopPost = "-${pkgs.fuse3}/bin/fusermount3 -u ${m.mountPoint}";
                  Restart = "on-failure";
                  RestartSec = "10s";
                  KillMode = "process";
                };
              };
            }) config.cococoir.storage.mounts;
            rpcPort = 3901;
            adminPort = 3903;
            region = "garage";
            bucketNames = builtins.attrNames config.cococoir.storage.buckets;
            mountNames = builtins.attrNames config.cococoir.storage.mounts;
            s3KeyDir = lib.dirOf config.clan.core.vars.generators.garage-global-s3-key.files.access-key-id.path;
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
                # `bootstrap_peers` is REQUIRED for single-node clusters.
                # Without it, the local node enters the
                # "Doing a bootstrap/discovery step (not_configured)"
                # loop and never adds itself to its own cluster view.
                # `garage layout assign` then fails with
                # "0 nodes match '<self-addr>'". Setting the peer
                # list to `[me.address]` makes the local node connect
                # to itself on startup, exchange identities, and
                # register the local node in its own cluster. For
                # multi-node, this same option is used to list the
                # OTHER nodes' rpc_public_addrs (the role interface
                # documents "peers are auto-derived from other
                # machines' `address` settings" for that case).
                bootstrap_peers = [ me.address ];
                s3_api.bind_addr = "127.0.0.1:${toString s3ApiPort}";
                s3_api.s3_region = region;
                admin.bind_addr = "127.0.0.1:${toString adminPort}";
                s3_api.root_domain = "s3.${region}.local";
              };
            };

            # Systemd services: garage (with hardened LoadCredential +
            # static user), bucket-init (oneshot first-boot setup),
            # and one FUSE service per cococoir.storage.mounts entry
            # (lxcfs.nix pattern). The FUSE services are computed
            # in the outer let block as `fuseServices` and merged
            # in here via the attrset-update operator — `//` is not
            # valid inside an attrset literal.
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
                # NixOS's systemd-lib adds a default `path` for all
                # services (mkAfter, can't be overridden by an
                # environment.PATH line — NixOS's default wins
                # silently). Add our bins to NixOS's `path` list
                # with mkAfter so they get appended to the rendered
                # PATH=… line. Only bash, garage, coreutils: bucket-init.sh
                # used to parse a generated JSON config with jq, but the
                # per-instance values (address, zone, capacity, bucket
                # names) are now passed as CLI flags (--address,
                # --zone, --capacity, --bucket) — the script has no
                # JSON parser dependency. (The S3 key is read directly
                # from a file at $CLAN_VAR_S3_KEY_DIR, which is itself
                # a SOPS-decrypted clan-core var — the SOPS-direct
                # pattern, no JSON round-trip.)
                path = lib.mkAfter [
                  pkgs.bash
                  pkgs.garage
                  pkgs.coreutils
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  User = "garage";
                  Group = "garage";
                  WorkingDirectory = metaDir;
                  # Flag-based args: `--global-dir`, `--address`,
                  # `--zone`, `--capacity` for the named per-instance
                  # values, plus a `--bucket` flag per bucket name.
                  # Flag-based (not positional) so the script is
                  # self-documenting and order can't be confused.
                  ExecStart = lib.concatMapStringsSep " " lib.escapeShellArg (
                    [
                      "${./bucket-init.sh}"
                      "--global-dir" globalDir
                      "--address" me.address
                      "--zone" instanceName
                      "--capacity" me.capacity
                    ]
                    ++ lib.concatMap (b: [ "--bucket" b ]) bucketNames
                  );
                  # The `garage` CLI calls (key import, layout, bucket)
                  # hit the running daemon's admin API and need the same
                  # RPC secret the daemon uses. Mirror the daemon's
                  # LoadCredential + env so the CLI authenticates. Without
                  # this, the CLI prints "Error: No RPC secret provided"
                  # and exits 1.
                  LoadCredential = [
                    "rpc_secret:${config.clan.core.vars.generators.garage-rpc-secret.files.rpc-secret.path}"
                  ];
                  Environment = [
                    "GARAGE_RPC_SECRET_FILE=%d/rpc_secret"
                    "CLAN_VAR_S3_KEY_DIR=${s3KeyDir}"
                  ];
                };
              };
            }
            // fuseServices;

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
              # The bucket-init service runs as the static `garage` user
              # and needs to read these files. Set the generator output
              # to be owned by garage:garage with mode 0440 so the
              # service can read them without further LoadCredential
              # gymnastics. Mode 0440 (not 0444) is intentional: the
              # secret access key should still be group-restricted.
              files.access-key-id = {
                owner = "garage";
                group = "garage";
                mode = "0440";
              };
              files.secret-access-key = {
                owner = "garage";
                group = "garage";
                mode = "0440";
              };
              runtimeInputs = [ pkgs.coreutils pkgs.openssl ];
              # Garage's S3 access key format is strict on BOTH halves
              # and the validation runs at `garage key import` time.
              # If either is wrong, the import fails and the
              # bucket-init script exits non-zero. The exact error
              # messages, in order:
              #
              #   access key ID:  "starts with `GK`, followed by 12
              #                    hex-encoded bytes"
              #                   = `GK` + 24 hex chars + 2 = 26 chars
              #                    total
              #
              #   secret key:     "composed of 32 hex-encoded bytes"
              #                   = 64 hex chars, no `GK` prefix,
              #                    no base64 — same encoding as the
              #                    rpc_secret
              #
              # `openssl rand -hex N` is the right primitive for both
              # (NOT `-base64`). For the access key ID, N=12 (we
              # prepend `GK` ourselves with printf). For the secret
              # key, N=32.
              #
              # If you change either size, also rotate
              # `clan vars regenerate garage-global-s3-key` so the
              # on-disk file is regenerated.
              script = ''
                printf 'GK%s' "$(openssl rand -hex 12)" > "$out/access-key-id"
                openssl rand -hex -out "$out/secret-access-key" 32
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
