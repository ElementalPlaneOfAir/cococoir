# SPDX-License-Identifier: AGPL-3.0-or-later
#
# system-manager host shim — the NixOS option surface fortress's modules
# reference but system-manager's module system does NOT provide.
#
# ADR-035 applies fortress via system-manager (not nixos-rebuild).
# system-manager's option set is a subset of NixOS's. Two mechanics force
# an option to be declared even for a service that is OFF:
#   1. A fortress module's `mkIf <cond> { services.X = {...}; }` registers
#      a DEFINITION at `services.X` even when the condition is false — the
#      module system requires the option to exist for every definition.
#   2. Cross-module gating READS `config.services.X.enable` (e.g. media.nix
#      wires the *arr oneshots) — the option must exist AND expose `enable`.
#
# Rules for what goes here vs. an import:
#   - The service RUNS under system-manager  → import its nixpkgs module
#     (real unit + config generation), e.g. dex, caddy.
#   - The service is OFF in this config      → stub it here.
#   - Host-OS concern (kernel, btrfs scrub)  → stub + document host-ownership.
#
# Stubs must graduate to real imports as each service is turned on — a
# stubbed service generates no unit, so enabling it silently does nothing.
# Add a vmtest-wiring tripwire (`scripts/status.sh` L1) when graduating one.
{lib, ...}: let
  inherit (lib) mkOption types;

  mkStub = description:
    mkOption {
      type = types.submodule {
        freeformType = types.attrsOf types.anything;
        options.enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether the real nixpkgs module is active (stub: always false).";
        };
      };
      default = {};
      inherit description;
    };
in {
  options = {
    # Host-owned btrfs task options. system-manager does not run btrfs
    # scrub; the host manages btrfs. Real behavior belongs to the machine
    # (e.g. amon-sul's own NixOS config) — see ADR-035.
    services.btrfs = mkOption {
      type = types.submodule {
        freeformType = types.attrsOf types.anything;
      };
      default = {};
      description = "Host-owned btrfs task options (see host-shim.nix header).";
    };

    services.cryptpad = mkStub "Stub: cryptpad off here; import its nixpkgs module when enabled.";
    services.dnsmasq = mkStub "Stub: dnsmasq off here; import its nixpkgs module when enabled.";
    services.forgejo = mkStub "Stub: forgejo off here; import its nixpkgs module when enabled.";
    services.jellyfin = mkStub "Stub: jellyfin off here; import its nixpkgs module when enabled.";
    services.qbittorrent = mkStub "Stub: qbittorrent off here; import its nixpkgs module when enabled.";
    services.radarr = mkStub "Stub: radarr off here; import its nixpkgs module when enabled.";
    services.seerr = mkStub "Stub: seerr off here; import its nixpkgs module when enabled.";
    services.sonarr = mkStub "Stub: sonarr off here; import its nixpkgs module when enabled.";

    # nixpkgs' services.dex module bind-mounts this bundle into the dex
    # sandbox. NixOS declares it (security/pki); system-manager does not.
    security.pki.caBundle = mkOption {
      type = types.str;
      default = "/etc/ssl/certs/ca-certificates.crt";
      description = "CA bundle path (host-owned; see host-shim.nix header).";
    };
  };
}
