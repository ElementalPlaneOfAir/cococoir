# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg, localPeers, localHost, numZonesWithCapacity }:
let
  garagePackage = pkgs.garage_2;
in
{
  # ── Static: garage daemon config + state directories ─────────────────────
  services.garage = {
    enable = true;
    package = garagePackage;
    logLevel = "info";
    environmentFile = cfg.cluster.rpcSecretFile;

    settings = {
      metadata_dir = cfg.node.metaDir;
      data_dir = [
        {
          path = cfg.node.dataDir;
          capacity = if cfg.node.capacity == null then null else cfg.node.capacity;
        }
      ];
      replication_factor = "1";
      rpc_bind_addr = "${localHost}:${toString cfg.cluster.rpcPort}";
      rpc_public_addr = cfg.node.address;
      # Placeholder — the real secret is substituted in ExecStartPre below.
      # Garage reads the rpc_secret from this TOML, not from env, so we have
      # to do the substitution at boot.
      rpc_secret = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
      s3_api = {
        api_bind_addr = "${localHost}:${toString cfg.cluster.s3ApiPort}";
        s3_region = cfg.cluster.region;
      };
      admin = {
        api_bind_addr = "127.0.0.1:${toString cfg.cluster.adminPort}";
      };
    } // (if localPeers == [ ] then { } else {
      bootstrap_peers = localPeers;
    });
  };

  # ── Substitute the real RPC secret into the rendered config ──────────────
  # The upstream services.garage module writes /run/garage/garage.toml from
  # the `settings` attrset, but it can't read a file at eval time. We do
  # the substitution right before garage starts.
  systemd.services.garage.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.writeShellScript "garage-secret-substitute" ''
      set -euo pipefail
      SECRET=$(cat ${cfg.cluster.rpcSecretFile})
      if [ -z "$SECRET" ]; then
        echo "garage rpc secret file is empty" >&2
        exit 1
      fi
      if [ -f /run/garage/garage.toml ]; then
        ${pkgs.gnused}/bin/sed -i "s|XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX|$SECRET|g" /run/garage/garage.toml
      fi
    ''}"
  ];

  # ── State directory for derived files (node id, bucket keys) ─────────────
  systemd.tmpfiles.rules = [
    "d /var/lib/cococoir 0755 root root -"
    "d /var/lib/cococoir/garage 0755 root root -"
    "d /var/lib/cococoir/garage/buckets 0755 root root -"
  ];

  # ── Make garage and its admin API address available to other units ──────
  # Exposed via environment.d so subsequent oneshot services can read it
  # without hardcoding the port.
  environment.etc."cococoir/garage.env".text = ''
    GARAGE_ADMIN_URL=http://127.0.0.1:${toString cfg.cluster.adminPort}
    GARAGE_BIN=${garagePackage}/bin/garage
    GARAGE_NODE_ID=${cfg.node.id}
    GARAGE_NODE_ZONE=${cfg.node.zone}
    GARAGE_NODE_CAPACITY=${if cfg.node.capacity == null then "0" else toString cfg.node.capacity}
    COCOCOIR_BUCKETS_DIR=/var/lib/cococoir/garage/buckets
    COCOCOIR_GLOBAL_KEY_DIR=/var/lib/cococoir/garage/global
  '';
}
