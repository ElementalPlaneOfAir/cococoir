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
  caddy = applierConfig.systemd.services.caddy;
  svc = caddy.serviceConfig;
  execStart = lib.concatStringsSep " " (lib.toList (svc.ExecStart or []));
  caddyEnv = lib.toList (svc.Environment or []);
  fortressWants = applierConfig.systemd.targets.fortress.wants or [];
in
# Caddy must not run under a named OS account: nothing creates it, so
# systemd fails the unit with 217/USER before ExecStart.
assert lib.assertMsg ((svc.User or "") == "root" && (svc.Group or "") == "root")
  "applier-wiring: caddy.service does not run as root — the applier cannot create a `caddy` account (userborn is disabled), so the unit dies with status=217/USER";

# The account must actually be gone; a lingering users.users.caddy would
# mean the module still expects the OS to create it.
assert lib.assertMsg (!((applierConfig.users.users or {}) ? caddy))
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

{
  applier-wiring = pkgs.runCommand "fortress-applier-wiring" {} ''
    cat > $out <<EOF
    fortress applier-wiring (L1, ADR-035/036): PASS
      a public service renders Caddy under the applier
      caddy runs as root (no named OS account the applier cannot create)
      caddy reads its Caddyfile from the store, not /etc
      fortress.target starts caddy, so a public service is reachable
    EOF
  '';
}
