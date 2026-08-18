# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir edge box — system-manager config.
#
# The edge runs on a stock Debian image (Hetzner), so disk + networking
# + NIC are handled by the OS out of the box. system-manager applies
# only what cococoir needs: the merged edge binary, its systemd unit,
# local Redis, WireGuard, and the operator SSH key. No disko, no
# fstab, no bootloader — nothing that can break the boot.
#
# `cococoir-edge` is injected via `extraSpecialArgs` from the flake.
{
  config,
  lib,
  pkgs,
  cococoirEdgePkg,
  ...
}: {
  nixpkgs.hostPlatform = "x86_64-linux";

  # ── Packages ────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    redis
    wireguard-tools
    jq
  ];

  # ── Files in /etc ───────────────────────────────────────────────
  environment.etc = {
    # Operator SSH key (root). Debian's openssh reads this directly.
    "ssh/authorized_keys.d/root".text = ''
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtpDAeIfLOlZE5y/SaHQ8h60nqbPSWdStRsvux6ECbk nicole@vermissian
    '';
    # Redis config: AOF + appendfsync always (ADR-025 deliberate
    # durability, not default).
    "cococoir/redis.conf".text = ''
      bind 127.0.0.1
      port 6379
      appendonly yes
      appendfsync always
      dir /var/lib/redis
    '';
  };

  # ── WireGuard server ─────────────────────────────────────────────
  # Interface is static; PEERS are added at runtime by the control
  # plane (`wg set`), so signups need no config change. wg0.conf
  # (Address + ListenPort + the private key) is assembled by
  # provision-edge.sh from tofu's addressing — the private key never
  # lives in the repo.
  systemd.services.wg-quick-wg0 = {
    description = "WireGuard tunnel for cococoir edge";
    enable = true;
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.wireguard-tools}/bin/wg-quick up wg0";
      ExecStop = "${pkgs.wireguard-tools}/bin/wg-quick down wg0";
    };
  };

  # ── Redis (control-plane store) ──────────────────────────────────
  systemd.services.redis = {
    description = "Redis for cococoir control plane";
    enable = true;
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.redis}/bin/redis-server /etc/cococoir/redis.conf";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # ── The merged edge: forwarder + control plane ──────────────────
  systemd.services.cococoir-edge = {
    description = "Cococoir edge — forwarder + control plane";
    enable = true;
    after = ["network-online.target" "wg-quick-wg0.service" "redis.service"];
    wants = ["network-online.target" "wg-quick-wg0.service" "redis.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cococoirEdgePkg}/bin/cococoir-edge --subnet 2a01:4f9:c014:2c44::/64 --wg-subnet 10.10.0.0/24 --redis-url redis://127.0.0.1:6379 --api-addr 0.0.0.0:8081 --health-addr 127.0.0.1:9090";
      Restart = "on-failure";
      RestartSec = 5;
      # Runs as root to bind privileged ports (80, 443) with
      # IPV6_FREEBIND on customer /128s.
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}
