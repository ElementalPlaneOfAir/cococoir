# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — consolidated Rust crate, built with crane.
#
# One crate, two binaries:
#   bin/cococoir-edge   — VPS-side L4 forwarder
#   bin/cococoir-client — customer-box-side L4 forwarder
#
# Both wrap the same src/lib.rs (forwarder, health, logger, app). The
# v0 Go module (buildGoModule) was replaced by this Rust crate in the
# rust-forwarder-port arc; the CLI flags, config JSON schema, and
# /status contract are unchanged, so the systemd units in
# nix/nixos-modules/{edge,client}.nix and the edge-forward nixosTest
# need no edits.
#
# Built with crane (github:ipetkov/crane) instead of
# rustPlatform.buildRustPackage: crane splits `buildDepsOnly` (workspace
# deps, compiled once and cached in the store) from `buildPackage` (our
# crate, recompiled on a source change), so editing this crate doesn't
# rebuild every dependency from scratch. Cargo.lock is committed; crane
# vendors deps from it automatically.
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
  # The crate's source. `cleanCargoSource` keeps only what cargo needs
  # (Cargo.toml/lock + src) but drops `secretspec.toml` (an unknown
  # extension) — and `declare_secrets!` reads that toml at compile time
  # relative to CARGO_MANIFEST_DIR. So start from `cleanCargoSource`
  # (correct, avoids dragging unrelated files into the build) and layer
  # secretspec.toml back on top.
  src = lib.cleanSourceWith {
    src = craneLib.cleanCargoSource ./.;
    filter = path: type:
      (lib.cleanSourceFilter path type)
      || (baseNameOf path == "secretspec.toml");
  };
  commonArgs = {
    inherit src;
    pname = "cococoir";
    version = "0.1.0";
    cargoLock = ./Cargo.lock;
  };
  cargoLock = ./Cargo.lock;
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
  package = craneLib.buildPackage (
    commonArgs
    // {
      inherit cargoArtifacts;
      inherit cargoLock;

      # buildPackage names binaries after each src/bin basename
      # (`edge`, `client`). Rename to `cococoir-edge` / `cococoir-client`
      # so the systemd units in nix/nixos-modules/{edge,client}.nix find
      # a single, predictable name.
      postInstall = ''
        mv $out/bin/edge $out/bin/cococoir-edge
        mv $out/bin/client $out/bin/cococoir-client
      '';

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