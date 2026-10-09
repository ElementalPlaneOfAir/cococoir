# SPDX-License-Identifier: AGPL-3.0-or-later
# Fortress v2 — test suite.
#
# Test layers:
#   L0: `cargo test` on the Rust workspace. No /dev/kvm,
#       no QEMU. Catches forwarder regressions in seconds.
#   L1: pure option-tree evaluation. No VM, no QEMU. Catches
#       derivation bugs and contract-conformance drift.
#   L2: full nixosTest. Boots a QEMU/KVM VM with the fortress
#       module loaded. Catches "doesn't build" and "doesn't boot"
#       failures. Needs /dev/kvm.
#
# Future (v2.9 combined test):
#   L3: scripted HTTP/API calls simulating a real customer
#       signup, login, upload. Catches end-to-end flow bugs
#       across the v2 stack.
{pkgs, sopsModule ? null}:
let
  lib = pkgs.lib;
  # Built with crane (github:ipetkov/crane, injected into pkgs by the
  # flake): `buildDepsOnly` compiles the workspace deps once and caches
  # them, so a source change only rebuilds the crate itself.
  fortressPkg = pkgs.callPackage ../packages/fortress {};
  edgeTests = let raw = import ./edge {inherit pkgs fortressPkg;}; in {
    edge-forward = raw.edge-forward.test;
  };
  # ── L1: the edge's store wiring (ADR-029, single-node shape) ──────
  # The silent-drop class: a refactor resurrecting a local redis unit on
  # the edge template, or a --redis-url pointing at an in-node store,
  # would break the edge's contract with the external managed store (the
  # control plane's persistence). The rendered template is the authority;
  # this asserts structurally against the committed/evaluated template.
  edgeStoreWiring = let
    lib = pkgs.lib;
    tpl = builtins.readFile (../.. + "/remote-infra/tofu/templates/edge.nix.tftpl");
  in
    pkgs.runCommand "fortress-edge-store-wiring" {} ''
      cat > $out <<EOF
      fortress edge-store-wiring (L1, ADR-029): PASS
        no local redis unit/config on the edge template
        ExecStart carries no --redis-url (store URL is the REDIS_URL secret)
      EOF
      ${lib.optionalString (lib.hasInfix "systemd.services.redis" tpl || lib.hasInfix "--redis-url" tpl || lib.hasInfix "pkgs.redis" tpl) ''
        echo "edge template still wires a local redis — ADR-029 violation" >&2
        exit 1
      ''}
    '';
  # ── L1: the sops admin template renders the VALUE, not a PATH ─────
  # The silent-failure seam: the admin env template must interpolate
  # `config.sops.placeholder.<name>` (a token sops swaps for the decrypted
  # bcrypt hash at activation). Using `config.sops.secrets.<name>.path`
  # instead renders a /run/secrets/… file PATH into the env file — the
  # client reads a path as the hash and every dashboard login fails with
  # no eval error. This asserts the correct construct is present and the
  # path-construct is gone.
  sopsAdminTemplate = let
    src = builtins.readFile (../.. + "/nix/nixos-modules/sops-wire.nix");
  in
    pkgs.runCommand "fortress-sops-admin-template" {} ''
      cat > $out <<EOF
      fortress sops-admin-template (L1): PASS
        admin env template interpolates config.sops.placeholder (the secret VALUE)
        does not render config.sops.secrets.<name>.path (a file path) into the env
      EOF
      ${lib.optionalString (!(lib.hasInfix "config.sops.placeholder" src)) ''
        echo "sops-wire.nix admin template lost config.sops.placeholder —" >&2
        echo "it would render a secret PATH into the env file (auth breaks silently)." >&2
        exit 1
      ''}
      ${lib.optionalString (lib.hasInfix "adminSecretName}.path" src) ''
        echo "sops-wire.nix admin template uses the secret PATH (adminSecretName}.path)" >&2
        echo "instead of the value placeholder — the env file would carry a path." >&2
        exit 1
      ''}
    '';
  # The platform never mints a secret at runtime — `fortress-bootstrap`
  # mints each inventory key exactly once and seals it. If a key is added
  # to the inventory without adding it here, a box boots with a missing
  # credential and the consumer dies in a way that looks like a service
  # bug. Assert the two lists match.
  bootstrapInventory = let
    secretsSrc = builtins.readFile (../.. + "/nix/nixos-modules/secrets.nix");
    bootstrapSrc = builtins.readFile (../.. + "/scripts/fortress-bootstrap.sh");
  in
    pkgs.runCommand "fortress-bootstrap-inventory" {
      inherit secretsSrc bootstrapSrc;
    } ''
      printf '%s' "$secretsSrc" > secrets.nix
      printf '%s' "$bootstrapSrc" > bootstrap.sh
      keys=$(sed -n 's/^    "\([a-z0-9-]*\)" = {$/\1/p' secrets.nix)
      if [ -z "$keys" ]; then
        echo "fortress-bootstrap-inventory: parsed no keys from secrets.nix — the" >&2
        echo "extraction pattern drifted, so this check proves nothing." >&2
        exit 1
      fi
      missing=0
      for key in $keys; do
        if ! grep -qF "$key" bootstrap.sh; then
          echo "  MISSING from fortress-bootstrap.sh: $key" >&2
          missing=1
        fi
      done
      if [ "$missing" != 0 ]; then
        echo "fortress-bootstrap-inventory: the sealed inventory and the bootstrap" >&2
        echo "generator disagree — a box would boot without that credential." >&2
        exit 1
      fi
      cat > $out <<EOF
      fortress bootstrap-inventory (L1): PASS
        every fortress.secrets._inventory key is minted by fortress-bootstrap
      EOF
    '';
  contractConformanceTests = import ./contract-conformance {inherit pkgs;};
  docRefsTests = import ./doc-refs {inherit pkgs;};
  # ── L1: the machine-side applier trampoline (ADR-037) ────────────
  # The silent-drop class: `nixosModules.applier` is the ONLY fortress
  # module a machine flake imports, and it must expose the trampoline
  # WITHOUT pulling in the service stack. Importing `./fortress.nix` there
  # would drag the app closure back into the OS `nixos-rebuild` closure
  # (the coupling ADR-035 rejects); and if the apply unit lost its
  # `wantedBy`, fortress would not survive a reboot, because
  # `fortress-apply` installs into tmpfs /run/systemd/system.
  applierTrampoline = let
    applier = builtins.readFile (../.. + "/nix/nixos-modules/applier.nix");
    apply = builtins.readFile (../.. + "/nix/system-manager/apply.sh");
  in
    pkgs.runCommand "fortress-applier-trampoline" {} ''
      cat > $out <<EOF
      fortress applier-trampoline (L1, ADR-037): PASS
        nixosModules.applier is standalone (no service-stack import)
        fortress-bootstrap runs first-boot only, before apply
        fortress-apply is wanted by multi-user.target (runs every boot)
        fortress-apply roots its store build under a persistent gcroots link
      EOF
      ${lib.optionalString (!(lib.hasInfix "systemd.services.fortress-bootstrap" applier)) ''
        echo "applier.nix lost the fortress-bootstrap unit — nothing would" >&2
        echo "generate the magic folder on first boot." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "systemd.services.fortress-apply" applier)) ''
        echo "applier.nix lost the fortress-apply unit — fortress would never" >&2
        echo "be applied on a NixOS host." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "ConditionPathExists" applier)) ''
        echo "applier.nix lost the bootstrap ConditionPathExists — the" >&2
        echo "generator would run (and could mutate) on every boot." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "multi-user.target" applier)) ''
        echo "applier.nix no longer wires fortress-apply to multi-user.target" >&2
        echo "— fortress would not come back after a reboot." >&2
        exit 1
      ''}
      ${lib.optionalString (lib.hasInfix "./fortress.nix" applier || lib.hasInfix "mkFortressSystemConfig" applier || lib.hasInfix "nixos-modules/default" applier) ''
        echo "nixosModules.applier now imports the service stack — that" >&2
        echo "re-couples the app closure to nixos-rebuild (ADR-035)." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "gcroots" apply)) ''
        echo "apply.sh no longer roots its build — a nix-collect-garbage" >&2
        echo "would delete the unit tree and an offline reboot would fail." >&2
        exit 1
      ''}
    '';

  # ── L1: the ADR-035 applier's unit wiring ────────────────────────
  # The silent-drop class: `fortress.target` groups the enabled fortress
  # services and is the ONE thing the applier starts. Drop it — or point the
  # applier at `system-manager.target` — and fortress silently never comes up
  # (or its infra units, which mount /run/wrappers and rewrite /etc/passwd,
  # fight the host OS). The L2 `smtest-e2e` proves the running system; this
  # pins the wiring that makes it possible, in the same commit.
  systemManagerWiring = let
    fortress = builtins.readFile (../.. + "/nix/system-manager/fortress.nix");
    apply = builtins.readFile (../.. + "/nix/system-manager/apply.sh");
    network = builtins.readFile (../.. + "/nix/nixos-modules/network.nix");
    hostShim = builtins.readFile (../.. + "/nix/system-manager/host-shim.nix");
  in
    pkgs.runCommand "fortress-system-manager-wiring" {} ''
      cat > $out <<EOF
      fortress system-manager-wiring (L1, ADR-035): PASS
        fortress.target groups the enabled services' units
        userborn disabled (host OS owns users)
        fortress-apply starts fortress.target, never system-manager.target
        fortress-dns is fortress-owned, store-backed and DynamicUser
      EOF
      ${lib.optionalString (!(lib.hasInfix "systemd.targets.fortress" fortress)) ''
        echo "nix/system-manager/fortress.nix lost systemd.targets.fortress —" >&2
        echo "the applier would start nothing." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "journald.units" fortress)) ''
        echo "fortress.target no longer wires the enabled services' units." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "systemd.services.userborn.enable = false" fortress)) ''
        echo "userborn was re-enabled — it rewrites the host's /etc/passwd and" >&2
        echo "drags system-manager's Rust build into the applier's closure." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "systemctl start fortress.target" apply)) ''
        echo "fortress-apply no longer starts fortress.target." >&2
        exit 1
      ''}
      ${lib.optionalString (lib.hasInfix "systemctl start system-manager.target" apply) ''
        echo "fortress-apply starts system-manager.target — its infra units" >&2
        echo "(run-wrappers.mount, userborn) fight the host OS." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "systemd.services.fortress-dns" network)) ''
        echo "nix/nixos-modules/network.nix lost the fortress-dns unit —" >&2
        echo "the LAN DNS plane would generate nothing." >&2
        exit 1
      ''}
      ${lib.optionalString (lib.hasInfix "services.dnsmasq" network) ''
        echo "network.nix went back to nixpkgs' dnsmasq module — that module" >&2
        echo "writes /etc and declares an OS user, neither of which the ADR-035" >&2
        echo "applier can honor on a host whose /etc is read-only." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "DynamicUser = true" network)) ''
        echo "fortress-dns dropped DynamicUser — it would need an OS account" >&2
        echo "the applier cannot create, so the unit dies on any host whose" >&2
        echo "/etc/passwd the OS owns." >&2
        exit 1
      ''}
      ${lib.optionalString (lib.hasInfix "services.dnsmasq" hostShim) ''
        echo "host-shim still stubs dnsmasq — fortress-dns is fortress-owned" >&2
        echo "now, so that stub is dead weight and a silent no-op." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "RuntimeDirectory" network)) ''
        echo "fortress-dns lost RuntimeDirectory — dnsmasq insists on a pidfile" >&2
        echo "and dies (exit 3) when it cannot write one under a read-only /run." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "RestartSec" network)) ''
        echo "fortress-dns lost RestartSec — a bind that loses the race to DHCP" >&2
        echo "exhausts the start limit in a second and the plane dies permanently." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "fortress-dns.service" fortress)) ''
        echo "fortress.target no longer wants fortress-dns.service — the LAN" >&2
        echo "DNS plane would never start under the applier." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "\"caddy.service\"" fortress)) ''
        echo "fortress.target no longer wants caddy.service — Caddy is not a" >&2
        echo "catalog service so nothing else pulls it in, and the applier" >&2
        echo "never starts system-manager.target. Every public service would" >&2
        echo "be unreachable." >&2
        exit 1
      ''}
      ${lib.optionalString (!(lib.hasInfix "nameserver" apply)) ''
        echo "fortress-apply lost its resolver-loop check — the module's" >&2
        echo "networking.nameservers assertion is vacuous on this path." >&2
        exit 1
      ''}
    '';
  # crane's `cargoArtifacts` from the package build are shared by every
  # Rust check, so deps compile once across `nix build`, `nix flake
  # check`, and the edge systemConfig.
  craneLib = pkgs.crane.mkLib pkgs;
  rustTestArgs = {
    src = fortressPkg.src;
    pname = "fortress";
    version = "0.1.0";
    cargoLock = fortressPkg.cargoLock;
    cargoArtifacts = fortressPkg.cargoArtifacts;
  };
in {
  # ── L0: forwarder Rust unit tests ────────────────────────────────
  # `cargo test` on the fortress crate. No /dev/kvm, no QEMU.
  # Catches regressions in the forwarder (TCP/UDP forwarding,
  # retry-with-backoff, graceful shutdown, proto validation) plus the
  # control-plane (signup/DNS/auth) and dashboard suites.
  forwarder-unit-tests = craneLib.cargoTest rustTestArgs;

  # ── L0b: the `redis-tests` tier must COMPILE ─────────────────────
  # The store-backed tier sits behind `redis-tests` (default off), so
  # `forwarder-unit-tests` never sees it. That is a silent-rot seam: a
  # helper used only inside `#[cfg(feature = "redis-tests")]` looks
  # dead to the default build and can be deleted with every check
  # still green — which is exactly how `TEST_EDGE_WG_PRIV` (used by
  # four gated tests, seen as "never used" by the default lint) was
  # dropped on 2026-09-25. This compiles the tier. It deliberately
  # does NOT run it: the tests need a live Redis, which the L2
  # `edge-forward` nixosTest provides.
  redis-tier-compiles = craneLib.cargoBuild (rustTestArgs // {
    cargoExtraArgs = "--locked -p fortress-controlplane --all-targets --features redis-tests";
  });

# ── L2: edge <-> client over WireGuard ───────────────────────────
  # 2-VM nixosTest. Exercises the control-plane edge's full
  # signup -> /128 -> WireGuard -> box path: a real POST /signup on the
  # edge (Redis-backed, IPV6_FREEBIND /128 bind) -> WireGuard tunnel ->
  # cofortress-client (box) -> 127.0.0.1:80 (python http server, Caddy
  # stand-in). See nix/tests/edge/default.nix for the full design.
} // edgeTests // { inherit edgeStoreWiring sopsAdminTemplate bootstrapInventory systemManagerWiring applierTrampoline; } // contractConformanceTests // docRefsTests
