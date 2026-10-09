# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress applier — system-manager (ADR-035). Composes fortress's modules
# with the nixpkgs service modules they wrap, evaluated by `makeSystemConfig`
# so fortress lands on the target's systemd OUTSIDE `nixos-rebuild` — uniform
# across NixOS and non-NixOS, version-independent of the machine's OS. The
# customer `config.nix` (services + remote-access + users) is the app config
# this consumes. Applied by `fortress-apply` (./apply.sh), not by
# `system-manager switch`: see apply.sh for why the stock activator is unsafe
# on NixOS.
{
  config,
  lib,
  inputs,
  nixosModulesPath,
  ...
}: let
  fortressLib = import ../lib/fortress.nix {inherit lib;};
in {
  imports = [
    # sops-nix materializes the sealed inventory at boot. system-manager
    # already stubs the `system.activationScripts` hooks sops-nix declares
    # (nix/modules/upstream/sops-nix.nix, pulled in via upstream/nixpkgs),
    # so the module imports cleanly — but those stubs are no-ops, which is
    # why `sops.useSystemdActivation` is forced below.
    inputs.sops-nix.nixosModules.sops
    # nixpkgs service modules fortress wraps that are ENABLED in this
    # config. Disabled services' `mkIf`-false definitions still need their
    # options to exist (see host-shim.nix) — those are stubbed there and
    # graduate here, one import per service, as each is turned on.
    ../nixos-modules
  ]
  ++ (import (nixosModulesPath + "/module-list.nix"));

  # system-manager's upstream/nixpkgs/default.nix declares NixOS options
  # (`boot`, `programs.bash.completion`, `fonts.fontconfig`, ...) as leaf
  # stubs so that a partial module import still evaluates. Once the real
  # module list is imported those stubs conflict — the module system
  # forbids an option and nested options at the same path. Drop the stub
  # file entirely; module-list provides every option for real.

  # NixOS and Debian already own system users and /run/wrappers. userborn
  # would rewrite the host's /etc/passwd out from under the OS, and its Rust
  # build would drag toolchain + binaries into the closure the applier
  # installs. The applier never starts system-manager's infra target, so drop
  # userborn (and its legacy importer) at the source: fortress services use
  # systemd DynamicUser or users the OS declares.
  systemd.services.userborn.enable = false;
  systemd.services.userborn-import-legacy.enable = false;

  # ── sops-nix: install secrets from a unit, not an activation script ──
  #
  # sops-nix has two install paths: `system.activationScripts.setupSecrets`
  # (NixOS activation) or `systemd.services.sops-install-secrets`. Under
  # system-manager the activation script is a no-op stub, and its default
  # for `useSystemdActivation` keys off `services.userborn.enable` /
  # `systemd.sysusers.enable` — neither of which the applier wants. Without
  # forcing this, declaring a secret *evaluates* fine and silently decrypts
  # nothing at boot. Force the unit path.
  sops.useSystemdActivation = true;

  # sops-nix hangs its installer off `sysinit-reactivation.target`, which
  # the applier deliberately never starts (see below). Hang it off the
  # target the applier *does* start, so secrets exist before any service.
  # Gated: declaring ordering for a service that does not exist would
  # create it without an ExecStart.
  systemd.services.sops-install-secrets = lib.mkIf (
    config.sops.useSystemdActivation
    && (config.sops.secrets != {} || config.sops.templates != {})
  ) {
    wantedBy = ["fortress.target"];
    requiredBy = ["fortress.target"];
    before = ["fortress.target"];
  };

  assertions = [
    {
      assertion = config.sops.secrets == {} || config.systemd.services ? sops-install-secrets;
      message = ''
        fortress: secrets are declared but no `sops-install-secrets` unit
        exists. sops-nix would fall back to `system.activationScripts`,
        which system-manager stubs out — the secrets would silently never
        be written. Keep `sops.useSystemdActivation = true`.
      '';
    }
  ];

  # ── Caddy: adapt upstream's module to the applier ──────────────────
  # Upstream's caddy module assumes nixos-rebuild owns the host: it
  # declares a `caddy` account (default.nix:501) and reads its config from
  # /etc/caddy/caddy_config (:525). The applier can do neither — userborn
  # is disabled above, and NixOS owns /etc (ADR-035). Two adaptations:
  #
  #   Identity — run as root. ADR-036 permits root where a dynamic user is
  #   impossible. The module sets `User = cfg.user` unconditionally and
  #   `serviceConfig` has no `null` (its generator toStrings every value),
  #   so User/Group cannot be cleared to let DynamicUser take over without
  #   re-deriving the whole unit. Root matches every other applier service
  #   that needs a stable identity (jellyfin, the *arr stack). The upstream
  #   unit keeps NoNewPrivileges + ProtectSystem; the bounding set below
  #   trims root to the only two capabilities Caddy uses.
  #
  #   Config — ExecStart/ExecReload read the store-rendered Caddyfile
  #   (`configFile`) directly, not the /etc path the applier never writes.
  services.caddy.user = "root";
  services.caddy.group = "root";
  systemd.services.caddy.serviceConfig = {
    CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE"];
    # As a named user, systemd homes Caddy at its StateDirectory
    # (/var/lib/caddy); as root it homes it at /root, which the upstream
    # unit's ProtectHome hides — Caddy then cannot write its cert store
    # (`/root/.local/share/caddy`) or config autosave (`/root/.config/caddy`)
    # and dies on first use. Point HOME at the state dir explicitly.
    Environment = ["HOME=${config.services.caddy.dataDir}"];
    ExecStart = lib.mkForce [
      ""
      "${lib.getExe config.services.caddy.package} run --config ${
        config.services.caddy.configFile
      }${lib.optionalString (config.services.caddy.adapter != null) " --adapter ${config.services.caddy.adapter}"}"
    ];
    ExecReload = lib.mkForce [
      ""
      "${lib.getExe config.services.caddy.package} reload --config ${
        config.services.caddy.configFile
      }${lib.optionalString (config.services.caddy.adapter != null) " --adapter ${config.services.caddy.adapter}"} --force"
    ];
  };

  # The applier starts exactly this target — never `system-manager.target`.
  # system-manager's infra units (userborn, run-wrappers.mount, the setuid
  # wrappers) manage the host OS's users and /run/wrappers, which NixOS and
  # Debian already own; starting them fights the OS (a tmpfs over NixOS's
  # setuid-wrappers dir, userborn rewriting /etc/passwd). Grouping the enabled
  # fortress services under this target lets the applier bring up exactly
  # fortress and nothing else.
  systemd.targets.fortress = {
    wantedBy = ["multi-user.target"];
    # The LAN DNS plane is network infrastructure, not a catalog service,
    # so it is not reachable through `fortress.services.*` — name it here.
    # Caddy likewise: it is not a fortress service (it is the ingress every
    # public one is fronted by), and the applier never starts
    # `system-manager.target`, which is where its own unit would otherwise
    # hang. Without this a public service is unreachable.
    wants =
      lib.optional config.fortress.network.dns.enable "fortress-dns.service"
      ++ lib.optional config.services.caddy.enable "caddy.service"
      # Units that hang themselves off this target (wantedBy/requiredBy)
      # join the set the applier starts and restarts — otherwise a unit
      # hanging off multi-user.target is installed but never started.
      ++ lib.concatMap (
        kind: let
          units = config.systemd.${kind} or {};
          suffix = {services = ".service"; sockets = ".socket"; timers = ".timer"; mounts = ".mount"; paths = ".path"; slices = ".slice";}.${kind};
        in
          lib.optionals (builtins.isAttrs units && suffix != null)
          (lib.mapAttrsToList (base: _: base + suffix)
            (lib.filterAttrs (_: u:
              builtins.elem "fortress.target" (lib.toList (u.wantedBy or []) ++ lib.toList (u.requiredBy or []))
            ) units))
      ) ["services" "sockets" "timers" "mounts" "paths" "slices"]
      ++ lib.concatMap (
        name: config.fortress.services.${name}.journald.units
      ) (
        # `fortress.services` also holds plain toggles that are not
        # routed services (e.g. `media`, the *arr wiring machinery) —
        # only factory-built entries carry `journald.units`.
        fortressLib.routedServiceNames config.fortress.services
      );
  };
}
