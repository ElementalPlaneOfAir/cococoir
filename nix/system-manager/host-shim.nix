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
#   - The service is fortress-owned          → no stub and no import: the
#     unit lives in the shared module tree and works on both paths, e.g.
#     fortress-dns (network.nix). nixpkgs' dnsmasq module is not used —
#     — it writes /etc and declares an OS user.
#
# Stubs must graduate to real imports as each service is turned on. A
# stubbed service is WORSE than a silent no-op: the fortress wrapper still
# emits its `systemd.services.<name>` block (ordering, serviceConfig,
# preStart) but the nixpkgs module that supplies `ExecStart` is absent, so
# you get a unit that systemd refuses to start. The assertions below make
# that loud. Add a vmtest-wiring tripwire when graduating one.
{
  config,
  lib,
  ...
}: let
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

  stubbedServices = ["cryptpad" "forgejo" "jellyfin" "qbittorrent" "radarr" "seerr" "sonarr"];
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
    services.forgejo = mkStub "Stub: forgejo off here; import its nixpkgs module when enabled.";
    services.jellyfin = mkStub "Stub: jellyfin off here; import its nixpkgs module when enabled.";
    services.qbittorrent = mkStub "Stub: qbittorrent off here; import its nixpkgs module when enabled.";
    services.radarr = mkStub "Stub: radarr off here; import its nixpkgs module when enabled.";
    services.seerr = mkStub "Stub: seerr off here; import its nixpkgs module when enabled.";
    services.sonarr = mkStub "Stub: sonarr off here; import its nixpkgs module when enabled.";

    # network.nix asserts the box does not resolve through its own
    # fortress-dns. The host's resolver is an OS concern this layer cannot
    # see, so the stub claims "no such server" and the assertion is vacuous
    # here — fortress-apply re-checks the live /etc/resolv.conf instead.
    networking.nameservers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Host resolver list (host-owned; see host-shim.nix header).";
    };

    # nixpkgs' services.dex module bind-mounts this bundle into the dex
    # sandbox. NixOS declares it (security/pki); system-manager does not.
    security.pki.caBundle = mkOption {
      type = types.str;
      default = "/etc/ssl/certs/ca-certificates.crt";
      description = "CA bundle path (host-owned; see host-shim.nix header).";
    };
  };

  config = {
    assertions = map (name: {
      assertion = !config.services.${name}.enable;
      message = ''
        fortress: `services.${name}.enable = true`, but ${name} is still a
        stub on the applier path (host-shim.nix) — its nixpkgs module is
        not imported, so the unit would be built without an ExecStart and
        systemd would refuse to start it. Graduate ${name} first: import
        its nixpkgs module in system-manager/fortress.nix and drop the
        stub here.
      '';
    }) stubbedServices;
  };
}
