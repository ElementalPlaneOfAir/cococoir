# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — top-level module.
#
# Aggregates the platform's NixOS modules. The flake's
# `nixosModules.default` ultimately imports this file (via
# default.nix).
#
# v2 architecture (see PLAN.md):
#   - cococoir.tls — TLS posture (off / acme / self-signed),
#     read by the service contract factory's Caddy vhost builder
#   - cococoir.baseDomain — apex domain; service domains derive
#     from it so customer configs stay small
#   - cococoir.secrets — sops-nix secret inventory (Phase 2)
#   - cococoir.storage.* — btrfs pool + subvolumes (ADR-023)
#   - cococoir.services.<name> — 4-option (or 3-option for
#     infra) contract; built via services/_contract.nix
#   - services.cococoir-{edge,client} — v0 L4 forwarder systemd
#     units (no-op on a v2 single-machine with no WireGuard peer)
{
  imports = [
    ./tls.nix
    ./base-domain.nix
    ./secrets.nix
    ./storage/btrfs.nix
    ./edge.nix
    ./client.nix
    ./services/jellyfin.nix
    ./services/dex.nix
    ./services/cryptpad.nix
    ./services/radarr.nix
    ./services/sonarr.nix
    ./services/lidarr.nix
    ./services/prowlarr.nix
    ./integrations/jellyfin-oidc.nix
    ./integrations/cryptpad-oidc.nix
  ];
}
