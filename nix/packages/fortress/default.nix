# SPDX-License-Identifier: AGPL-3.0-or-later
# Fortress v2 — Rust workspace, built with crane.
#
# Three crates, two binaries:
#   crates/core           — shared L4 forwarder engine (no binaries)
#   crates/controlplane   — cofortress-edge (the edge box's single process)
#   crates/client         — cofortress-client (forwarder + embedded dashboard)
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
  # The workspace root (this file lives at nix/packages/fortress/, so
  # the root is three levels up). crane's own `cleanCargoSource` keeps
  # only .rs / .toml / Cargo.lock / .cargo/config — and nested
  # cleanSourceWith layers compose conjunctively, so a filter applied
  # on top of an already-filtered tree can NOT resurrect files the
  # inner filter dropped (verified empirically 2026-09-18). So the
  # filter below is a UNION evaluated directly against the raw tree:
  #   - the .rs / .toml / Cargo.lock / .cargo/config rules crane keeps
  #   - `secretspec.toml`              (crates/*/secretspec.toml — read
  #                                    at compile time by declare_secrets!)
  #   - `*.md` under /content/docs/    the site wiki markdown
  #                                    (include_str! in crates/site)
  #   - `*.js` under any `/assets/`    vendored SPA assets (crates/web-ui)
  #   - `install.sh`                   scripts/install.sh (include_str! in
  #                                    crates/controlplane/…/web.rs)
  # Files outside the allowlist are pruned; the junk dirs (.git,
  # .direnv, target, result) survive as empty, fileless dirs.
  src = lib.cleanSourceWith {
    src = ../../..;
    filter = path: type:
      (type == "directory")
      || (lib.any (suffix: lib.hasSuffix suffix (baseNameOf path)) [
        ".rs"
        ".toml"
      ])
      || (baseNameOf path == "Cargo.lock")
      || (baseNameOf path == "secretspec.toml")
      || (lib.hasSuffix ".md" (baseNameOf path) && lib.hasInfix "/content/docs/" path)
      || (lib.hasSuffix ".js" (baseNameOf path) && lib.hasInfix "/assets/" path)
      || (baseNameOf path == "install.sh");
  };
  commonArgs = {
    inherit src;
    pname = "fortress";
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
      # bins are already `fortress-edge` and `fortress-client`, so the
      # systemd units find a single, predictable name with no rename.
      meta = with lib; {
        description = "Fortress v2 — L4 TCP/UDP forwarder (edge and client binaries)";
        homepage = "https://github.com/ElementalPlaneOfAir/fortress";
        license = licenses.agpl3Plus;
        mainProgram = "fortress-edge";
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