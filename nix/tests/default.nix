# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — test suite.
#
# Test layers:
#   L0: `cargo test` on the Rust workspace. No /dev/kvm,
#       no QEMU. Catches forwarder regressions in seconds.
#   L1: pure option-tree evaluation. No VM, no QEMU. Catches
#       derivation bugs and contract-conformance drift.
#   L2: full nixosTest. Boots a QEMU/KVM VM with the cococoir
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
  cococoirPkg = pkgs.callPackage ../packages/cococoir {};
  edgeTests = let raw = import ./edge {inherit pkgs cococoirPkg;}; in {
    edge-forward = raw.edge-forward.test;
  };
  contractConformanceTests = import ./contract-conformance {inherit pkgs;};
  docRefsTests = import ./doc-refs {inherit pkgs;};
in {
  # ── L0: forwarder Rust unit tests ────────────────────────────────
  # `cargo test` on the cococoir crate. No /dev/kvm, no QEMU.
  # Catches regressions in the forwarder (TCP/UDP forwarding,
  # retry-with-backoff, graceful shutdown, proto validation) plus the
  # control-plane (signup/DNS/auth) and dashboard suites.
  #
  # Uses crane's `cargoTest` reusing the same `cargoArtifacts` as the
  # package build, so the deps are compiled once and shared across
  # `nix build`, `nix flake check`, and the edge systemConfig.
  forwarder-unit-tests = let
    craneLib = pkgs.crane.mkLib pkgs;
    commonArgs = {
      src = cococoirPkg.src;
      pname = "cococoir";
      version = "0.1.0";
      cargoLock = cococoirPkg.cargoLock;
      cargoArtifacts = cococoirPkg.cargoArtifacts;
    };
  in
    craneLib.cargoTest commonArgs;

# ── L2: edge <-> client over WireGuard ───────────────────────────
  # 2-VM nixosTest. Exercises the control-plane edge's full
  # signup -> /128 -> WireGuard -> box path: a real POST /signup on the
  # edge (Redis-backed, IPV6_FREEBIND /128 bind) -> WireGuard tunnel ->
  # cocococoir-client (box) -> 127.0.0.1:80 (python http server, Caddy
  # stand-in). See nix/tests/edge/default.nix for the full design.
} // edgeTests // contractConformanceTests // docRefsTests
