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
  # The landing page is the product surface: a service missing from the
  # catalog is running and unreachable from the one page a customer
  # looks at. Assert the catalog the unit will read covers every service
  # the routing plane routes.
  fortressLib = import ../../lib/fortress.nix {inherit lib;};
  catalogNames = map (e: e.name) (fortressLib.mkCatalog cfg.fortress.services);
  routedRows = ["jellyfin" "radarr" "sonarr" "seerr" "qbittorrent"];
  missingFromCatalog = builtins.filter (n: !(builtins.elem n catalogNames)) routedRows;
  # Inspect what modules *declare*, not only the merged value: a
  # `mkForce []` would hide a bad declaration from the merged check while
  # the rule is still wrong for the applier surface. `definitions` is the
  # pre-merge contribution of every module.
  declaredTmpfiles = lib.concatLists (map lib.toList
    ((applierConfig.options.systemd.tmpfiles.rules.definitions or [])));
  # The failure mode is narrow and worth asserting precisely: a module
  # creating APP STATE through tmpfiles, which the applier never applies,
  # so the path silently never exists and the unit dies at boot.
  # Everything NixOS core contributes under /run/lock, /var/db, /nix/var,
  # /lib64, /var/empty and friends is host-OS by ADR-035 — the host
  # already has those paths, so they are not this bug.
  # A state-root rule is only acceptable when a unit in the closure
  # creates that path anyway (StateDirectory / ExecStartPre) — the rule is
  # then inert under the applier and harmless. Named here with its
  # mechanism so a NEW state-root tmpfiles rule still fails.
  unitCreatedStateDirs = [
    # services/jellyfin.nix: systemd.services.jellarr.serviceConfig.StateDirectory
    "/var/lib/jellarr"
    # jellarr's preStart `install -D` creates dataDir/config
    "/var/lib/jellarr/config"
  ];
  stateRoots = [
    cfg.fortress.storage.dataRoot
    "/var/lib"
    "/etc/fortress"
  ];
  tmpfilesStateRule = r:
    lib.any (root: lib.hasInfix root r) stateRoots
    && !(lib.any (d: lib.hasInfix d r) unitCreatedStateDirs);
  unexpectedTmpfiles = lib.filter tmpfilesStateRule (lib.unique declaredTmpfiles);

# ── the routing plane must actually route ───────────────────────────
# Enabling a service is only half the job: planes.nix has to emit its
# `@row-<name>` handler into the Caddyfile. On amon-sul a whole media stack
# came up on its ports while Caddy still 502'd every path, because the
# rendered Caddyfile contained dex and nothing else. Assert the rows exist.
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

  # ── jellarr must actually be in the module list ────────────────────
  # jellarr is a flake input, not a nixpkgs module, so `module-list.nix`
  # does not supply it. Every consumer gates on `options.services ?
  # jellarr` with `lib.optionalAttrs` — and when that is false the block
  # is dropped WITHOUT ERROR: no jellarr.service and no
  # jellarr-api-key-bootstrap.service, the oneshot that inserts the
  # sealed jellarr-api-key into Jellyfin's ApiKeys table. That is exactly
  # what shipped to amon-sul: the key went stale after a secret rotation
  # and fortress-media-apply crash-looped 62 times on a 401 it read as
  # "not ready". Assert the units exist and the gate is taken.
  jellarrEnabled = cfg.services.jellarr.enable or false;
  mediaApply = (cfg.systemd.services or {}).fortress-media-apply or null;
  mediaApplyAfter =
    if mediaApply == null then [] else lib.toList (mediaApply.after or []);

  # Rows that strip their prefix AND proxy to the app. The failover
  # aliases strip too, but they redirect to another origin rather than to
  # the slash form, so they are out of scope. Mirrors planes.nix's
  # `routable` + `proxyHandle` predicate.
  strippedProxyPaths =
    let
      routable = lib.filterAttrs
        (_: s: (s.enable or false) && (s ? path) && (s ? routing))
        cfg.fortress.services;
    in
    lib.mapAttrsToList (_: s: s.path)
      (lib.filterAttrs (_: s: s.public && s.routing == "path" && (s.stripPath or false)) routable);

  # Services whose own login is disabled in favour of the Dex gate. If the
  # gate row goes missing from the Caddyfile these are OPEN DOORS — the *arr
  # `External` handler is the same as `None` (Servarr, Sonarr#5252) and
  # qBittorrent trusts the loopback source. Shipped exactly that way on
  # amon-sul: every LAN device had full qBittorrent control.
  gatedRows =
    lib.mapAttrsToList (name: s: {inherit name; group = s.accessGroup;})
      (lib.filterAttrs (_: s: (s.accessGroup or null) != null) cfg.fortress.services);
  gatedGroups = lib.unique (map (r: r.group) gatedRows);
in
assert lib.assertMsg (missingInfra == [])
  "applier-wiring: these units are enabled but NOT reachable from fortress.target (the applier starts only fortress.target, so they would never run): ${builtins.toJSON missingInfra}";

# jellarr is a flake input, so it is absent from the module list unless
# fortress.nix imports it. Without it every `options.services ? jellarr`
# gate is false and the guarded block vanishes silently.
assert lib.assertMsg (lib.hasAttrByPath ["services" "jellarr"] cfg)
  "applier-wiring: services.jellarr is not in the option tree — the jellarr nixosModule is missing from the applier's imports, so jellarr.service and jellarr-api-key-bootstrap.service are never declared and the sealed Jellyfin API key is never inserted";
assert lib.assertMsg (!(cfg.fortress.services.jellyfin.enable or false) || jellarrEnabled)
  "applier-wiring: jellyfin is enabled but services.jellarr.enable is false — the optionalAttrs gate on `options.services ? jellarr` did not fire, so Jellyfin gets no API key and no declarative config";
assert lib.assertMsg (!(cfg.fortress.services.jellyfin.enable or false)
  || builtins.elem "jellarr.service" closure)
  "applier-wiring: jellyfin is enabled but jellarr.service is not in the applier closure — declarative Jellyfin config would never apply on first boot";
assert lib.assertMsg (!(cfg.fortress.services.jellyfin.enable or false)
  || builtins.elem "jellarr-api-key-bootstrap.service" closure)
  "applier-wiring: jellyfin is enabled but jellarr-api-key-bootstrap.service is not in the applier closure — the sealed jellarr-api-key is never inserted into Jellyfin's ApiKeys, so every authed integration 401s permanently";
assert lib.assertMsg (!(cfg.fortress.services.jellyfin.enable or false)
  || builtins.elem "jellarr.timer" closure)
  "applier-wiring: jellyfin is enabled but jellarr.timer is not in the applier closure — upstream hangs it off timers.target, which the applier never starts, so jellarr's periodic re-apply silently never runs";
assert lib.assertMsg (!(cfg.fortress.services.seerr.enable or false)
  || builtins.elem "jellarr-api-key-bootstrap.service" mediaApplyAfter)
  "applier-wiring: fortress-media-apply is not ordered after jellarr-api-key-bootstrap — it can win the race, find no API key, and report a 401 as 'not ready'";

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
assert lib.assertMsg (lib.hasInfix "-catalog /nix/store/" clientExec && !(lib.hasInfix "-catalog /etc/" clientExec))
  "applier-wiring: fortress-client does not read the service catalog from a store path — a catalog that rode /etc is silently absent under the applier, and the landing page renders with no services";
assert lib.assertMsg (missingFromCatalog == [])
  "applier-wiring: these routed services are missing from the dashboard catalog (${builtins.toJSON missingFromCatalog}) — they would be running but invisible on the landing page, which is the one page a customer looks at";

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
  applier-wiring = pkgs.runCommand "fortress-applier-wiring"
    {
      caddyfile = cfg.services.caddy.configFile;
      mediaApplyScript =
        if mediaApply == null then pkgs.writeText "no-media-apply" ""
        else lib.head (lib.toList mediaApply.serviceConfig.ExecStart);
    }
    ''
    # The routing plane must actually route: on amon-sul a whole media stack
    # came up on its ports while Caddy 502'd every path, because the
    # rendered Caddyfile contained dex and nothing else. Build-time, so the
    # derivation output is readable (pure eval forbids reading it at eval).
    CF=$(find "$caddyfile" -name Caddyfile -o -name Caddyfile-formatted 2>/dev/null | head -1)
    [ -n "$CF" ] && [ -f "$CF" ] || CF=$(find "$caddyfile" -type f | head -1)
    for row in jellyfin radarr sonarr seerr qbittorrent; do
      if ! grep -q "@row-$row" "$CF"; then
        echo "applier-wiring: @row-$row missing from the Caddyfile ($CF) —" >&2
        echo "rows: $(grep -oE '@row-[a-z0-9-]+' "$CF" | sort -u | tr '\n' ' ')" >&2
        exit 1
      fi
    done

    # A prefix-stripped path must redirect its bare form to the trailing
    # slash. qBittorrent emits relative asset URLs, so at `/qbittorrent`
    # the browser resolves `css/style.css` against `/`, gets a 404, and the
    # UI renders unstyled. Shipped to amon-sul as "the css on qbittorrent
    # doesn't seem to be showing up".
    ${lib.optionalString (strippedProxyPaths != []) ''
      for p in ${lib.escapeShellArgs strippedProxyPaths}; do
        if ! grep -qF "redir $p/ 307" "$CF"; then
          echo "applier-wiring: the bare path $p does not redirect to $p/ in" >&2
          echo "the Caddyfile ($CF). $p strips its prefix, so an app that" >&2
          echo "emits relative asset URLs has them resolve against / and 404." >&2
          exit 1
        fi
      done
    ''}

    # The gate is the ONLY auth in front of these apps — their own logins are
    # off (`AuthenticationMethod=External`, `LocalHostAuth=true`). A row that
    # loses its `forward_auth` does not degrade to a login page; it becomes an
    # open door. Shipped exactly that way on amon-sul, where every LAN device
    # had full qBittorrent control (unauthenticated API writes included).
    ${lib.optionalString (gatedRows != []) ''
      for row in ${lib.escapeShellArgs (map (r: r.name) gatedRows)}; do
        if ! grep -A4 "handle @row-$row {" "$CF" | grep -q "forward_auth"; then
          echo "applier-wiring: @row-$row has no forward_auth preflight in" >&2
          echo "the Caddyfile ($CF). $row's own login is disabled, so this" >&2
          echo "row would serve it to anyone who can reach caddy." >&2
          exit 1
        fi
      done
      for g in ${lib.escapeShellArgs gatedGroups}; do
        if ! grep -qF "allowed_groups=$g,admins" "$CF"; then
          echo "applier-wiring: no route admits gate group '$g' (with the" >&2
          echo "admins superset) in $CF. Either the group policy was lost or" >&2
          echo "gate-policy.nix stopped appending admins — which silently" >&2
          echo "locks the box owner out of their own services." >&2
          exit 1
        fi
      done
    ''}

    # The download-client category field is named per *arr. A bare
    # `category` is accepted by the API and silently discarded, so the
    # *arr keeps its default category and every torrent falls through to
    # qBittorrent's DefaultSavePath where nothing imports it. This
    # shipped to amon-sul as health errors on both *arrs.
    if [ -s "$mediaApplyScript" ]; then
      for field in movieCategory tvCategory; do
        if ! grep -q "$field" "$mediaApplyScript"; then
          echo "applier-wiring: fortress-media-apply never sets $field —" >&2
          echo "the download-client category would be silently dropped." >&2
          exit 1
        fi
      done
      if grep -qE '\{name: "category"' "$mediaApplyScript"; then
        echo "applier-wiring: fortress-media-apply sends the field name \"category\"" >&2
        echo "to the *arrs. That field does not exist; radarr/sonarr accept" >&2
        echo "the payload and discard it. Use movieCategory/tvCategory." >&2
        exit 1
      fi
    fi
    cat > $out <<EOF
    fortress applier-wiring (L1, ADR-035 amendment): PASS
      a public service renders Caddy under the applier
      every enabled public service has a @row-<name> route
      a prefix-stripped path redirects its bare form to the slash form
      every gated service row carries a forward_auth preflight
      every gate group is admitted (with the admins superset)
      caddy runs as root (no named OS account the applier cannot create)
      caddy reads its Caddyfile from the store, not /etc
      fortress.target starts caddy, so a public service is reachable
      positive applier surface: no tmpfiles beyond the baseline, no
      service referencing /etc, fortress-client config is store-pathed
      sops installs from a unit ordered before fortress.target
      jellarr is in the module list (API key bootstrap is not dropped)
      fortress-media-apply sets movieCategory/tvCategory, not "category"
    EOF
  '';
}
