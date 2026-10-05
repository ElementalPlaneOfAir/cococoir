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

  # The applier starts exactly this target — never `system-manager.target`.
  # system-manager's infra units (userborn, run-wrappers.mount, the setuid
  # wrappers) manage the host OS's users and /run/wrappers, which NixOS and
  # Debian already own; starting them fights the OS (a tmpfs over NixOS's
  # setuid-wrappers dir, userborn rewriting /etc/passwd). Grouping the enabled
  # fortress services under this target lets the applier bring up exactly
  # fortress and nothing else.
  systemd.targets.fortress = {
    wantedBy = ["multi-user.target"];
    wants = lib.concatMap (
      name: config.fortress.services.${name}.journald.units
    ) (
      lib.filter (name: config.fortress.services.${name}.enable)
      (builtins.attrNames config.fortress.services)
    );
  };
}
