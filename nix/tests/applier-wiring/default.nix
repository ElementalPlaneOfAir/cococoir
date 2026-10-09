# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress applier-wiring check.
#
# L1: pure option-tree evaluation against an applier config with a
# *public* service. No VM, no QEMU.
#
# Why this exists: the applier's runtime proof (`smtest-e2e`) shipped with
# its fixture on `dex.public = false`, so Caddy — the ingress every public
# service is fronted by — was never enabled on the applier path and its two
# gaps stayed invisible until the amon-sul cutover died on
# `caddy.service: status=217/USER` (2026-10-07):
#
#   1. upstream's caddy module declares a `caddy` account the applier cannot
#      create (userborn disabled, ADR-036), and
#   2. it reads its config from /etc/caddy/caddy_config, which the applier
#      never installs (ADR-035).
#
# The adaptation lives in nix/system-manager/fortress.nix. Assert it against
# the rendered config, not the source — a refactor that drops the override
# must fail here, in the same commit, before it reaches a boot.
{pkgs, applierConfig}:
let
  lib = pkgs.lib;
  # `applierConfig` is the whole eval result (it carries `applierUnitNames`
  # and `unitsDir`); the module tree lives under `.config`.
  cfg = applierConfig.config;
  caddy = cfg.systemd.services.caddy;
  svc = caddy.serviceConfig;
  execStart = lib.concatStringsSep " " (lib.toList (svc.ExecStart or []));
  caddyEnv = lib.toList (svc.Environment or []);
  fortressWants = cfg.systemd.targets.fortress.wants or [];

  # ── positive applier surface (ADR-035 amendment) ─────────────
  # The applier installs *units only*. Any effect a module expresses
  # through another activation mechanism — environment.etc, tmpfiles,
  # users, mounts — is silently absent on a customer box, and the only
  # symptom is a unit that dies at boot. So assert the *surface* at the
  # unit: no tmpfiles additions beyond system-manager's baseline, and no
  # service referencing /etc. The one sanctioned non-store reach is the
  # sops device age key. (We check unit *references*, not the etc option
  # itself — system-manager and upstream modules write a harmless,
  # unread baseline into it.)
  # Only enabled units reach the applier's surface (`unitsDir` filters on
  # `unit.enable`). The full NixOS module set declares hundreds of units
  # that stay disabled — asserting on those would be noise.
  services = lib.filterAttrs (n: _: builtins.elem n (cfg.applierUnitNames or []))
    (cfg.systemd.services or {});
  configRefs = name:
    let sc = services.${name}.serviceConfig or {};
    in lib.concatMap (k: lib.toList (sc.${k} or []))
      ["ExecStart" "ExecStartPre" "ExecReload" "ExecStop" "ExecStopPost"
       "EnvironmentFile" "Environment" "WorkingDirectory"];
  etcRefsAllowlist = ["/etc/fortress/system_age_keys.txt"];
  etcRefServices = lib.filter (name:
    lib.any (p: lib.hasInfix "/etc/" p && !(lib.any (a: lib.hasInfix a p) etcRefsAllowlist))
      (configRefs name))
    (lib.attrNames services);
  clientExec = lib.concatStringsSep " "
    (lib.toList (cfg.systemd.services.fortress-client.serviceConfig.ExecStart or []));
  applierTmpfiles = cfg.systemd.tmpfiles.rules or [];
  # The failure mode is narrow and worth asserting precisely: a module
  # creating APP STATE through tmpfiles, which the applier never applies,
  # so the path silently never exists and the unit dies at boot.
  # Everything NixOS core contributes under /run/lock, /var/db, /nix/var,
  # /lib64, /var/empty and friends is host-OS by ADR-035 — the host
  # already has those paths, so they are not this bug.
  stateRoots = [
    cfg.fortress.storage.dataRoot
    "/var/lib"
    "/etc/fortress"
  ];
  tmpfilesStateRule = r: lib.any (root: lib.hasInfix root r) stateRoots;
  unexpectedTmpfiles = lib.filter tmpfilesStateRule applierTmpfiles;

# ── sops under the applier ──────────────────────────────────────
  # sops-nix has two install paths: the NixOS activation script, or a
  # `sops-install-secrets` unit. system-manager stubs the activation
  # script out to a no-op (nix/modules/upstream/sops-nix.nix), and
  # `useSystemdActivation` defaults off unless sysusers/userborn are on —
  # neither of which the applier wants. Declaring a secret then evaluates
  # cleanly and decrypts *nothing* at boot. Assert the unit path is
  # taken and hung off the target the applier actually starts.
  installUnit = (cfg.systemd.services or {}).sops-install-secrets or null;
  installBefore = if installUnit == null then [] else lib.toList (installUnit.before or []);
  installRequiredBy = if installUnit == null then [] else lib.toList (installUnit.requiredBy or []);

  # The silent-drop class. The applier starts `fortress.target` and nothing
  # else, so a unit reachable ONLY from multi-user.target is installed into
  # /run/systemd/system and never runs — which is how fortress-plain-dirs,
  # fortress-client and fortress-media-apply silently did nothing on
  # amon-sul. nixpkgs' own services set `wantedBy = multi-user.target` and
  # are fine, because fortress.target pulls them; the bug is a unit that
  # fortress.target does NOT pull. So assert the fortress-owned infra units
  # are in the closure — that is the property that actually failed.
  closure = applierConfig.applierUnitNames or [];
  expectedInfra = lib.unique (
    [ "fortress-plain-dirs.service" ]
    ++ lib.optional (cfg.fortress.services.jellyfin.enable or false) "jellyfin.service"
    ++ lib.optional (cfg.fortress.services.radarr.enable or false
                     || cfg.fortress.services.sonarr.enable or false)
        "fortress-media-apply.service"
    ++ lib.optional (cfg.fortress.services.qbittorrent.enable or false) "qbittorrent.service"
  );
  missingInfra = lib.filter (n: !(builtins.elem n closure)) expectedInfra;
in
assert lib.assertMsg (missingInfra == [])
  "applier-wiring: these units are enabled but NOT reachable from fortress.target (the applier starts only fortress.target, so they would never run): ${builtins.toJSON missingInfra}";

# Caddy must not run under a named OS account: nothing creates it, so
# systemd fails the unit with 217/USER before ExecStart.
assert lib.assertMsg ((svc.User or "") == "root" && (svc.Group or "") == "root")
  "applier-wiring: caddy.service does not run as root — the applier cannot create a `caddy` account (userborn is disabled), so the unit dies with status=217/USER";

# The account must actually be gone; a lingering users.users.caddy would
# mean the module still expects the OS to create it.
assert lib.assertMsg (!((cfg.users.users or {}) ? caddy))
  "applier-wiring: the applier still declares users.users.caddy — nothing creates it, so caddy.service cannot start";

# The config must come from the store: /etc/caddy/caddy_config is generated
# into the closure but apply.sh installs only systemd/system, so a unit that
# reads /etc starts with no config (and reloads do nothing).
assert lib.assertMsg (lib.hasInfix "--config /nix/store/" execStart && !(lib.hasInfix "/etc/" execStart))
  "applier-wiring: caddy.service reads its Caddyfile from /etc — the applier never installs environment.etc, so Caddy starts with no configuration";

# As root, systemd homes Caddy at /root, which the upstream unit's
# ProtectHome hides — Caddy then cannot write its cert store or config
# autosave and dies on first use. HOME must point at its writable state dir.
assert lib.assertMsg (lib.any (e: lib.hasPrefix "HOME=" e) caddyEnv)
  "applier-wiring: caddy.service does not set HOME — as root it defaults to /root, which ProtectHome hides, so Caddy cannot write its cert store and dies";

# Caddy is not a catalog service, so nothing but fortress.target pulls it in
# under the applier (which never starts system-manager.target).
assert lib.assertMsg (builtins.elem "caddy.service" fortressWants)
  "applier-wiring: fortress.target does not want caddy.service — a public service would be unreachable under the applier";

# ── positive applier surface (ADR-035 amendment) ──────────────
# The applier installs units only. These assertions keep every module
# inside that surface, so a module that reaches for /etc or tmpfiles
# fails here — in the same commit — instead of silently on a box.
assert lib.assertMsg (unexpectedTmpfiles == [])
  "applier-wiring: the applier composition declares systemd.tmpfiles.rules (${builtins.toJSON unexpectedTmpfiles}) — the applier never applies tmpfiles, so those dirs silently never exist. Create them from a unit instead";
assert lib.assertMsg (etcRefServices == [])
  "applier-wiring: a service references /etc (${builtins.toJSON etcRefServices}) — the applier never materializes /etc, so the unit starts with no config. A unit's inputs must be store paths (only the sops age key is exempt)";
assert lib.assertMsg (lib.hasInfix "-config /nix/store/" clientExec && !(lib.hasInfix "/etc/" clientExec))
  "applier-wiring: fortress-client reads its config from /etc — the applier never installs environment.etc, so the dashboard starts with no config (the amon-sul 502, 2026-10-08)";

# ── a service is a config line, not a code change ──────────────────
# The L1 fixture enables `fortress.services.jellyfin`. Before the
# module-list change that required importing nixpkgs' jellyfin module by
# hand and deleting a stub in host-shim.nix; now it is one config line
# and the unit lands in the applier's closure. Assert both halves —
# the option resolving AND the unit being installed — so regressing to
# per-service "graduation" fails here.
assert lib.assertMsg (builtins.elem "jellyfin.service" (applierConfig.applierUnitNames or []))
  "applier-wiring: jellyfin is enabled in the fixture but its unit is not in the applier closure — enabling a service is supposed to be a config line";

# ── sops under the applier ───────────────────────────────────────
# Secrets must decrypt from a unit, not from the stubbed activation
# script — otherwise they silently never exist.
assert lib.assertMsg (cfg.sops.useSystemdActivation or false)
  "applier-wiring: sops.useSystemdActivation is not forced true — sops-nix would fall back to system.activationScripts, which system-manager stubs to a no-op, so secrets silently never decrypt";
assert lib.assertMsg (installUnit != null)
  "applier-wiring: secrets are declared but no sops-install-secrets unit exists — nothing would decrypt them at boot";
assert lib.assertMsg (builtins.elem "fortress.target" installBefore && builtins.elem "fortress.target" installRequiredBy)
  "applier-wiring: sops-install-secrets is not ordered before fortress.target — a service can start before its secret exists";

{
  applier-wiring = pkgs.runCommand "fortress-applier-wiring" {} ''
    cat > $out <<EOF
    fortress applier-wiring (L1, ADR-035 amendment): PASS
      a public service renders Caddy under the applier
      caddy runs as root (no named OS account the applier cannot create)
      caddy reads its Caddyfile from the store, not /etc
      fortress.target starts caddy, so a public service is reachable
      positive applier surface: no tmpfiles beyond the baseline, no
      service referencing /etc, fortress-client config is store-pathed
      sops installs from a unit ordered before fortress.target
    EOF
  '';
}
