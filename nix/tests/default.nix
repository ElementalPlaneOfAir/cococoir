# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — test suite.
#
# Test layers:
#   L0: `go test ./...` on the cococoir Go module. No /dev/kvm,
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
  edgeTests = let raw = import ./edge {inherit pkgs;}; in {
    edge-forward = raw.edge-forward.test;
  };
  storageTests = let
    raw = import ./storage {inherit pkgs; sopsModule = if sopsModule == null then [] else [ sopsModule ];};
  in {
    storage = raw.storage.test;
  };
  contractConformanceTests = import ./contract-conformance {inherit pkgs;};
  cococoirPkg = pkgs.callPackage ../packages/cococoir {};
in {
  # ── L0: forwarder Go unit tests ──────────────────────────────────
  # `go test ./...` on the cococoir module. No /dev/kvm, no
  # QEMU. Catches regressions in the forwarder (TCP/UDP
  # forwarding, retry-with-backoff, graceful shutdown, proto
  # validation). See
  # nix/packages/cococoir/internal/forwarder/forwarder_test.go.
  forwarder-unit-tests = cococoirPkg.overrideAttrs (_: {
    doCheck = true;
  });

  # ── v2 gate: 1-VM nixosTest for the storage layer ──────────────
  # Single NixOS VM with sops-nix + Garage + FUSE mount + native
  # S3 PUT/GET. Exercises the storage option tree, sops-nix
  # secret decryption, the bucket-init oneshot, the FUSE
  # service, and the S3 client path.
  # See nix/tests/storage/default.nix for the full design.

  # ── L2: edge <-> client over WireGuard ───────────────────────────
  # 2-VM nixosTest. Exercises the full L4-forwarder-over-WG path:
  # cococoir-edge (VPS, per-IP bind at 192.168.1.10:80) ->
  # WireGuard tunnel -> cococoir-client (box) -> 127.0.0.1:80
  # (python http server, Caddy stand-in). See
  # nix/tests/edge/default.nix for the full design.
} // edgeTests // storageTests // contractConformanceTests
