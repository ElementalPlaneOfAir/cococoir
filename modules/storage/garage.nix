# SPDX-License-Identifier: AGPL-3.0-or-later
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cococoir.storage;
  garagePackage = pkgs.garage_2;
  localHost = builtins.elemAt (lib.splitString ":" cfg.node.address) 0;
  localPeers = lib.filter (p: p != cfg.node.address) cfg.cluster.bootstrapPeers;
  numZonesWithCapacity = builtins.length (lib.filter
    (z: z.capacity != null && z.capacity != 0)
    cfg.cluster.layout.zones);
in {
  # ── Static: garage daemon config + state directories ─────────────────────
  config = lib.mkIf cfg.enable {
    users.users.garage = {
      isSystemUser = true;
      group = "garage";
      home = cfg.node.metaDir;
      description = "Garage Object Storage daemon";
    };
    users.groups.garage = {};

    services.garage = {
      enable = true;
      package = garagePackage;
      logLevel = "info";
      environmentFile = cfg.cluster.rpcSecretFile;

      settings =
        {
          metadata_dir = cfg.node.metaDir;
          data_dir = [
            {
              path = cfg.node.dataDir;
              capacity =
                if cfg.node.capacity == null
                then null
                else cfg.node.capacity;
            }
          ];
          replication_factor = 1;
          rpc_bind_addr = "${localHost}:${toString cfg.cluster.rpcPort}";
          rpc_public_addr = cfg.node.address;
          # Placeholder — the real secret is substituted in ExecStartPre below.
          rpc_secret = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
          s3_api = {
            api_bind_addr = "${localHost}:${toString cfg.cluster.s3ApiPort}";
            s3_region = cfg.cluster.region;
          };
          admin = {
            api_bind_addr = "127.0.0.1:${toString cfg.cluster.adminPort}";
          };
        }
        // (
          if localPeers == []
          then {}
          else {
            bootstrap_peers = localPeers;
          }
        );
    };

    # ── Substitute the real RPC secret into the rendered config ───────────
    # Override the nixpkgs module's `DynamicUser = lib.mkDefault true` and
    # drop its empty `StateDirectory` (it only sets StateDirectory when the
    # default /var/lib/garage path is used; for our custom paths under
    # /var/lib/cococoir/garage/ we use tmpfiles below and a static user).
    systemd.services.garage.serviceConfig = {
      DynamicUser = false;
      User = "garage";
      Group = "garage";
    };
    # The nixpkgs services.garage module writes the rendered TOML to
    # /etc/garage.toml (via environment.etc."garage.toml".source = configFile).
    # Sed that file in place to replace the placeholder with the real
    # secret from the clan vars generator.
    systemd.services.garage.serviceConfig.ExecStartPre = lib.mkBefore [
      "+${pkgs.writeShellScript "garage-secret-substitute" ''
        set -euo pipefail
        SECRET=$(cat ${cfg.cluster.rpcSecretFile})
        if [ -z "$SECRET" ]; then
          echo "garage rpc secret file is empty" >&2
          exit 1
        fi
        if [ ! -f /etc/garage.toml ]; then
          echo "/etc/garage.toml not found" >&2
          exit 1
        fi
        ${pkgs.gnused}/bin/sed -i "s|XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX|$SECRET|g" /etc/garage.toml
      ''}"
    ];

    # ── State directory for derived files (node id, bucket keys) ──────────
    # Includes dataDir + metaDir so systemd can bind-mount them into the
    # daemon's mount namespace (the nixpkgs services.garage unit sets
    # `ReadWritePaths = [dataDir metaDir]` for non-default paths, and
    # systemd will fail with NAMESPACE if the dirs don't exist).
    systemd.tmpfiles.rules = [
      "d /var/lib/cococoir 0755 root root -"
      "d /var/lib/cococoir/garage 0755 root root -"
      "d ${cfg.node.dataDir} 0750 garage garage -"
      "d ${cfg.node.metaDir} 0750 garage garage -"
      "d /var/lib/cococoir/garage/buckets 0755 root root -"
      "d /var/lib/cococoir/garage/global 0750 root root -"
    ];

    # ── Make garage and its admin API address available to other units ────
    environment.etc."cococoir/garage.env".text = ''
      GARAGE_ADMIN_URL=http://127.0.0.1:${toString cfg.cluster.adminPort}
      GARAGE_BIN=${garagePackage}/bin/garage
      GARAGE_NODE_ID=${cfg.node.id}
      GARAGE_NODE_ZONE=${cfg.node.zone}
      GARAGE_NODE_CAPACITY=${
        if cfg.node.capacity == null
        then "0"
        else toString cfg.node.capacity
      }
      COCOCOIR_BUCKETS_DIR=/var/lib/cococoir/garage/buckets
      COCOCOIR_GLOBAL_KEY_DIR=/var/lib/cococoir/garage/global
      NUM_ZONES_WITH_CAPACITY=${toString numZonesWithCapacity}
    '';
  };
}
