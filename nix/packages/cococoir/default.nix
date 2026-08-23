# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Rust workspace, built with crane.
#
# Three crates, two binaries:
#   crates/core           — shared L4 forwarder engine (no binaries)
#   crates/controlplane   — cocococoir-edge (the edge box's single process)
#   crates/client         — cocococoir-client (forwarder + embedded dashboard)
#
# Built with crane (github:ipetkov/crane): `buildDepsOnly` compiles the
# workspace deps once (cached in the store), `buildPackage` recompiles
# just our crates on a source change. Cargo.lock lives at the workspace
# root and is committed; crane vendors deps from it.
#
# The derivation exposes `src` / `cargoLock` / `cargoArtifacts` as
# passthru so `nix/tests` can build `cargoTest` over the SAME cached
# deps as the package — one dependency compilation shared across
# `nix build`, `nix flake check`, and the edge systemConfig.
{
  lib,
  pkgs,
  crane,
}:
let
  craneLib = crane.mkLib pkgs;
  # The workspace root (this file lives at nix/packages/cococoir/, so
  # the root is three levels up). `cleanCargoSource` keeps only what
  # cargo needs (Cargo.toml/lock + src) but drops `secretspec.toml` (an
  # unknown extension) — and `declare_secrets!` reads that toml at
  # compile time relative to CARGO_MANIFEST_DIR. So layer the tomls back
  # on top.
  src = lib.cleanSourceWith {
    src = craneLib.cleanCargoSource ../../..;
    filter = path: type:
      (lib.cleanSourceFilter path type)
      || (baseNameOf path == "secretspec.toml");
  };
  commonArgs = {
    inherit src;
    pname = "cococoir";
    version = "0.1.0";
    cargoLock = ../../../Cargo.lock;
    # Cap cargo's parallelism so the first full dependency build fits
    # in ~8GB of RAM (rustc is memory-hungry; the default uses every
    # core). `buildDepsOnly` compiles the whole dependency tree once, so
    # this only slows the cold build — later builds reuse the cached
    # artifacts and recompile just our crates.
    env = {
      CARGO_BUILD_JOBS = "2";
      CARGO_TEST_JOBS = "2";
    };
  };
  cargoLock = ../../../Cargo.lock;
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
  package = craneLib.buildPackage (
    commonArgs
    // {
      inherit cargoArtifacts;
      inherit cargoLock;

      # buildPackage names binaries after each src/bin basename; the
      # bins are already `cococoir-edge` and `cococoir-client`, so the
      # systemd units find a single, predictable name with no rename.
      meta = with lib; {
        description = "Cococoir v2 — L4 TCP/UDP forwarder (edge and client binaries)";
        homepage = "https://github.com/ElementalPlaneOfAir/cococoir";
        license = licenses.agpl3Plus;
        mainProgram = "cococoir-edge";
        platforms = platforms.linux;
      };
    }
  );
in
  package
  // {
    passthru = (package.passthru or {})
    // {
      inherit src cargoArtifacts cargoLock;
    };
  }