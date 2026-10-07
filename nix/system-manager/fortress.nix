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
  nixosModulesPath,
  ...
}: {
  imports = [
    # nixpkgs service modules fortress wraps that are ENABLED in this
    # config. Disabled services' `mkIf`-false definitions still need their
    # options to exist (see host-shim.nix) — those are stubbed there and
    # graduate here, one import per service, as each is turned on.
    (nixosModulesPath + "/services/web-apps/dex.nix")
    # planes.nix renders Caddy vhosts AND references `services.caddy.enable`
    # unconditionally, so caddy's module is always required (even when no
    # service is public).
    (nixosModulesPath + "/services/web-servers/caddy/default.nix")
    ./host-shim.nix
    ../nixos-modules
  ];

  # NixOS and Debian already own system users and /run/wrappers. userborn
  # would rewrite the host's /etc/passwd out from under the OS, and its Rust
  # build would drag toolchain + binaries into the closure the applier
  # installs. The applier never starts system-manager's infra target, so drop
  # userborn (and its legacy importer) at the source: fortress services use
  # systemd DynamicUser or users the OS declares.
  systemd.services.userborn.enable = false;
  systemd.services.userborn-import-legacy.enable = false;

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
      ++ lib.concatMap (
        name: config.fortress.services.${name}.journald.units
      ) (
        lib.filter (name: config.fortress.services.${name}.enable)
        (builtins.attrNames config.fortress.services)
      );
  };
}
