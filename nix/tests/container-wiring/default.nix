# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress container-wiring check.
#
# L1: pure option-tree evaluation against the *actual* fortress
# container nixosConfiguration. No VM, no QEMU, no docker. Catches
# the regression classes that are invisible on the btrfs customer
# tier and break the container tier:
#   - btrfs machinery leaking into the container (pool units,
#     supportedFilesystems, mounts)
#   - a service's storage paths or btrfs unit refs escaping the
#     storage backend split (the source-level half of that
#     tripwire lives in contract-conformance; this asserts the
#     rendered config)
#   - the Caddy 0.0.0.0 bind (docker's userland proxy needs it)
#     being dropped by a refactor of the contract factory
#   - the demo-base extraction silently dropping config
#     (dex users, service enables)
# Why evaluate the real nixosConfiguration: the tier lives in the
# composition of fortress-container.nix with the fortress modules;
# only the real composition is a faithful tripwire.
{pkgs, containerConfig}: let
  lib = pkgs.lib;

  c = containerConfig;

  enabledDomains = let
    enabled = lib.filterAttrs (_: s: (s.enable or false) && (s ? domain))
      c.fortress.services;
  in lib.mapAttrsToList (_: s: s.domain) enabled;

  everyVhostBindsWildcard = builtins.all (d:
    lib.hasInfix "bind 127.0.0.1 0.0.0.0"
      c.services.caddy.virtualHosts."${d}".extraConfig)
    enabledDomains;

  tmpfiles = c.systemd.tmpfiles.rules;
  hasTmpfileDir = path: lib.any (r: lib.hasInfix " ${path} " ("${r} ")) tmpfiles;

  noBtrfsServices =
    !(c.systemd.services ? fortress-btrfs-subvolumes)
    && !(c.systemd.services ? fortress-btrfs-pool);

  noBtrfsMounts = builtins.all (m: (m.type or "") != "btrfs") c.systemd.mounts;

  jellyfinUnit = c.systemd.services.jellyfin;
  dexUsers = c.services.dex.settings.staticPasswords or [];
in
# ── backend selection ───────────────────────────────────────
assert lib.assertMsg (c.fortress.storage.enable && c.fortress.storage.backend == "plain-dirs")
  "container-wiring: the container tier must run the plain-dirs storage backend";
assert lib.assertMsg (c.fortress.storage.dataRoot == "/data")
  "container-wiring: container dataRoot must be /data (the bind-mounted volume)";
assert lib.assertMsg c.boot.isContainer
  "container-wiring: boot.isContainer is not set — the docker-container profile was dropped";
assert lib.assertMsg (c.networking.hostName == "fortress-container")
  "container-wiring: the container identity was not forced (dashboard.nix's vmtest hostName leaked)";

# ── btrfs must not leak into the container ──────────────────
assert lib.assertMsg noBtrfsServices
  "container-wiring: a fortress-btrfs-* unit rendered in the container tier — the btrfs backend's mkIf gate was lost";
assert lib.assertMsg noBtrfsMounts
  "container-wiring: a btrfs mount rendered in the container tier";
assert lib.assertMsg (!(c.boot.supportedFilesystems.btrfs or false))
  "container-wiring: boot.supportedFilesystems.btrfs is on in the container tier";

# ── plain-dirs tmpfiles consumed the declarations ───────────
assert lib.assertMsg (hasTmpfileDir "/data/cryptpad/data"
  && hasTmpfileDir "/data/jellyfin/metadata"
  && hasTmpfileDir "/data/media/movies"
  && hasTmpfileDir "/data/media/shows/library"
  && hasTmpfileDir "/data/forgejo")
  "container-wiring: the auto-declared subvolume tree did not render as /data tmpfiles rules — the plain-dirs backend lost the declarations";
assert lib.assertMsg (lib.all (r: !lib.hasInfix "btrfs" r) tmpfiles)
  "container-wiring: a btrfs reference leaked into the container tmpfiles rules";

# ── service paths follow dataRoot, btrfs refs don't ─────────
assert lib.assertMsg (lib.hasInfix "/data" (builtins.head (map (f: (builtins.head f.libraryOptions.pathInfos).path) (lib.filter (f: f.name == "Movies") c.services.jellarr.config.library.virtualFolders))))
  "container-wiring: the Jellyfin Movies library does not live under the container dataRoot";
assert lib.assertMsg (!(lib.elem "fortress-btrfs-subvolumes.service" jellyfinUnit.after)
  && !(lib.elem "fortress-btrfs-subvolumes.service" jellyfinUnit.requires))
  "container-wiring: jellyfin still orders after fortress-btrfs-subvolumes.service — the gate regressed";

# ── Caddy wildcard bind survives composition ────────────────
assert lib.assertMsg everyVhostBindsWildcard
  "container-wiring: an enabled vhost does not bind 0.0.0.0 — docker's userland proxy connects to the container's eth0 IP, and a loopback-only bind is a closed port";

# ── demo-base extraction survived ───────────────────────────
assert lib.assertMsg (dexUsers != [] && lib.all (u: u ? hash) dexUsers)
  "container-wiring: dex staticPasswords did not render — the demo-base extraction dropped the test users";
assert lib.assertMsg (c.fortress.services.jellyfin.enable && c.fortress.services.dex.enable)
  "container-wiring: a core service enable was dropped from the container tier";

# ── the image is buildable ──────────────────────────────────
assert lib.assertMsg (c.system.build.tarball ? drvPath)
  "container-wiring: system.build.tarball is not a derivation";
{
  container-wiring = pkgs.runCommand "fortress-container-wiring" {} ''
    cat > $out <<EOF
    fortress container-wiring: PASS
      tier: plain-dirs backend, dataRoot=/data, boot.isContainer, hostName forced
      btrfs: no pool/subvolume units, no btrfs mounts, no supportedFilesystems.btrfs
      storage: subvolume tree rendered as /data tmpfiles (cryptpad, jellyfin, media)
      paths: jellyfin libraries under /data; no btrfs unit refs in service units
      ingress: every vhost binds 127.0.0.1 0.0.0.0 (docker userland proxy)
      demo-base: dex users + service enables survive the extraction
    EOF
  '';
}
