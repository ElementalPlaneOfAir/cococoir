# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir — edge service module.
#
# The edge box runs one process (the merged forwarder + control plane):
# `cococoir-edge --subnet ... --redis-url ...`. It forwards customer
# /128s to their WG peers (live, via IPV6_FREEBIND), and the control
# plane API signs customers up. See the control-plane-source-of-truth
# proposal.
#
# The module also enables the local Redis the control plane persists
# to (AOF + appendfsync always, per ADR-025: durability is deliberate,
# not assumed).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.cococoir-edge;
  edgePkg = pkgs.callPackage ../packages/cococoir {};
in {
  options.services.cococoir-edge = {
    enable = lib.mkEnableOption "cococoir edge service (forwarder + control plane)";

    subnet = lib.mkOption {
      type = lib.types.str;
      description = "The edge box's routed IPv6 subnet (e.g. 2a01:4f8:c17:1::/64). Customers get /128s carved from it.";
    };

    wgSubnet = lib.mkOption {
      type = lib.types.str;
      default = "10.10.0.0/24";
      defaultText = lib.literalExpression "10.10.0.0/24";
      description = "WireGuard tunnel network (edge .1, customers .2+).";
    };

    redisUrl = lib.mkOption {
      type = lib.types.str;
      default = "redis://127.0.0.1:6379";
      defaultText = lib.literalExpression "redis://127.0.0.1:6379";
      description = "Redis the control plane persists customers to. Defaults to the local Redis this module enables.";
    };

    apiAddr = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:8081";
      defaultText = lib.literalExpression "0.0.0.0:8081";
      description = "Address for the control plane HTTP API (signup/delete/customers).";
    };

    healthAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9090";
      defaultText = lib.literalExpression "127.0.0.1:9090";
      description = "Address for the /healthz, /readyz, /status HTTP endpoints. Localhost-only by default.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = edgePkg;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/cococoir {}";
      description = "cococoir package. Override to point at a fork or pinned version.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.redis.servers.cococoir = {
      enable = true;
      port = 6379;
      appendOnly = true;
      appendFsync = "always"; # ADR-025: durability deliberate, not default
    };

    systemd.services.cococoir-edge = {
      description = "Cococoir edge — forwarder + control plane";
      after = ["network-online.target" "wireguard-wg0.service" "redis-cococoir.service"];
      wants = ["network-online.target" "redis-cococoir.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/cococoir-edge --subnet ${cfg.subnet} --wg-subnet ${cfg.wgSubnet} --redis-url ${cfg.redisUrl} --api-addr ${cfg.apiAddr} --health-addr ${cfg.healthAddr}";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening. Runs as root because it binds privileged ports
        # (80, 443) with IPV6_FREEBIND on customer /128s.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [];
      };
    };
  };
}