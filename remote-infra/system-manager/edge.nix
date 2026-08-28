# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir edge box — system-manager config.
#
# Rendered by tofu from remote-infra/tofu/main.tf — do not hand-edit.
# The addressing (edge_ipv6_subnet, wg_subnet, wg_listen_port) flows
# from tofu so there is exactly one source of truth for the deployed
# addressing, matching the DNS records and the provision script.
#
# The edge runs on a stock Debian image (Hetzner), so disk + networking
# + NIC are handled by the OS out of the box. system-manager applies
# only what cococoir needs: the merged edge binary, its systemd unit,
# local Redis, WireGuard, and the operator SSH key. No disko, no
# fstab, no bootloader — nothing that can break the boot.
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
    caddy
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
    # Caddy fronts the edge's own control plane at https://interdim.net
    # (apex A/AAAA -> edge IPv4 + ::1). It proxies the single merged edge
    # handler on 0.0.0.0:8081 — the control-plane API plus the /healthz
    # /readyz /status endpoints (the edge serves both from one poem app),
    # incl. the swagger UI at /docs and spec at /openapi.json — so a
    # booting customer box's dashboard and an operator reach the join
    # surface, health, and the swagger UI over TLS. Caddy binds ONLY the
    # edge's own addresses (IPv4 + ::1) so it never shadows the
    # forwarder's customer /128 listeners (e.g. ::3:80/443).
    "caddy/Caddyfile".text = ''
      interdim.net {
        bind 62.238.111.21 2a01:4f9:c014:2c44::1
        reverse_proxy 127.0.0.1:8081
      }
    '';
  };

  # ── WireGuard server ─────────────────────────────────────────────
  # wg-quick brings wg0 up; the interface's real identity (its private
  # key) is owned by cococoir-edge, which generates + persists it in
  # Redis and installs it into wg0 on boot. wg0.conf carries only a
  # throwaway key so the interface can come up; PEERS are added at
  # runtime by the control plane (`wg set`), so signups need no config
  # change. Address + listen port are assembled by provision-edge.sh
  # from tofu's single source of truth.
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
      # redis.conf sets `dir /var/lib/redis`; StateDirectory creates it
      # (a bare Debian image has no /var/lib/redis). LANG=C.UTF-8 so
      # redis 8.x's setlocale() doesn't abort on an unset locale.
      StateDirectory = "redis";
      Environment = "LANG=C.UTF-8";
    };
  };

  # ── Caddy (public HTTPS for the control plane) ──────────────────
  # Serves https://interdim.net over the edge's own IPv4 + ::1 and
  # proxies to the control-plane API. Binds only the edge's addresses
  # (per the Caddyfile) so it never collides with the forwarder's
  # customer /128 listeners. StateDirectory persists ACME certs/state.
  systemd.services.caddy = {
    description = "Caddy reverse proxy — cococoir control plane at https://interdim.net";
    enable = true;
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.caddy}/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile";
      StateDirectory = "caddy";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # ── The merged edge: forwarder + control plane ──────────────────
  # Unit name is `edge-control-plane`, NOT `cococoir-edge`: the systemd
  # NAME PREFIX `cococoir-edge` is corrupted on the edge box — systemd
  # starts such a unit at boot but un-tracks it on the first daemon-reload
  # (is-active/cat/start all report "not found"), so no system-manager
  # switch could ever restart it. Verified: identical unit content loads
  # fine under any other name (e.g. zzz-edge-a), only `cococoir-edge*`
  # is refused. A non-`cococoir-edge` name sidesteps it.
  systemd.services.edge-control-plane = {
    description = "Cococoir edge — forwarder + control plane";
    enable = true;
    after = ["network-online.target" "wg-quick-wg0.service" "redis.service"];
    wants = ["network-online.target" "wg-quick-wg0.service" "redis.service"];
    wantedBy = ["multi-user.target"];
    # The binary shells out to `wg set` to install its runtime identity
    # into wg0; give the unit the wg binary on PATH (systemd's default
    # PATH lacks /run/current-system/sw/bin).
    path = [ pkgs.wireguard-tools ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cococoirEdgePkg}/bin/cococoir-edge --subnet 2a01:4f9:c014:2c44::/64 --wg-subnet 10.10.0.0/24 --redis-url redis://127.0.0.1:6379 --api-addr 0.0.0.0:8081 --ipv6-iface eth0";
      # The edge secrets (DNS zone + token, root domain, admin key
      # hash) are resolved by the secretspec SDK from /etc/cococoir/
      # (secretspec.toml + edge.env, written by provision-edge.sh, mode
      # 0600, never in the repo). WorkingDirectory=/etc/cococoir so the
      # SDK's CWD-walk finds secretspec.toml; EnvironmentFile lands the
      # dotenv values in the process env as a belt-and-suspenders. The
      # service fails at boot — not on first signup — if either file is
      # missing (SECRETS is a panic-on-fail LazyLock).
      WorkingDirectory = "/etc/cococoir";
      EnvironmentFile = "/etc/cococoir/edge.env";
      Restart = "on-failure";
      RestartSec = 5;
      # Runs as root to bind privileged ports (80, 443) with
      # IPV6_FREEBIND on customer /128s.
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}
