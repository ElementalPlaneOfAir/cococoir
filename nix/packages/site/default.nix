# SPDX-License-Identifier: AGPL-3.0-or-later
# Fortress site — the deployable dioxus fullstack bundle (ADR-033).
#
# Two artifacts:
#   bin/     — the SSR server binary (axum + render_handler fallback)
#   public/  — the wasm hydration bundle: index.html + wasm-bindgen glue
#
# dx is deliberately NOT in this derivation: it drives its own cargo
# builds with dx-internal profiles, so crane's buildDepsOnly caching
# never applies and every nix build would recompile the whole dep tree
# for both legs (~750 crates × 2 targets, ~20 min). Instead the two
# legs are plain cargo builds with crane caching (deps prebuild once;
# a site-only change recompiles just fortress-site), and the client
# glue is produced by an explicit wasm-bindgen step.
#
# The wasm-bindgen-cli version MUST exactly match the wasm-bindgen in
# Cargo.lock (0.2.127 — nixpkgs maxes at 0.2.105 and the lock can't
# downgrade to it: js-sys 0.3.104 via chrono requires newer), so the
# CLI is built here from the same version.
#
# dx remains a dev-shell tool: `dx build --platform web` / `dx serve`
# against a warm local target/ is the fast iteration loop.
{
  lib,
  pkgs,
  crane,
  rustOverlay,
}:
let
  # The dx client leg compiles for wasm32-unknown-unknown, so the wasm
  # toolchain must carry that std; the server leg uses the plain
  # (nixpkgs-default) toolchain so its deps cache is shared with the
  # fortress package. Pinned to the toolchain the dev environment uses
  # so rustc churn can't split local vs nix builds.
  rustPkgs = import pkgs.path {
    system = pkgs.system;
    overlays = [ rustOverlay.overlays.default ];
  };
  wasmToolchain = rustPkgs.rust-bin.stable."1.97.1".default.override {
    targets = [ "wasm32-unknown-unknown" ];
  };
  wasmCraneLib = (crane.mkLib pkgs).overrideToolchain (_: wasmToolchain);
  nativeCraneLib = crane.mkLib pkgs;

  wasmBindgenVersion = "0.2.127";
  wasmBindgenCli = pkgs.buildWasmBindgenCli rec {
    version = wasmBindgenVersion;
    src = pkgs.fetchCrate {
      inherit version;
      pname = "wasm-bindgen-cli";
      hash = "sha256-di+qBAdd7pENLiIB9CoZoab+W5xeDoByMREcCGTSzWo=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      inherit (src) pname version;
      hash = "sha256-FTv2GZIAQs0ePdIZXIXil7JbZ6kIT05VG6vqC1qNFxQ=";
    };
  };

  cargoLock = ../../../Cargo.lock;

  # Everything the site crate reads at compile time: the wiki markdown
  # (include_str!) and the embedded install script.
  src = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      (nativeCraneLib.fileset.commonCargoSources ../../..)
      # fileFilter's file.name is the basename, so anchor the filter on
      # the content dir itself.
      (lib.fileset.fileFilter (file: file.hasExt "md") ../../../crates/site/content)
      (lib.fileset.maybeMissing ../../../scripts/install.sh)
      (lib.fileset.maybeMissing ../../../crates/site/public/index.html)
    ];
  };

  commonArgs = {
    inherit src cargoLock;
    pname = "fortress-site";
    version = "0.1.0";
    strictDeps = true;
    # Only the site crate — the workspace has other binaries (edge,
    # client) this bundle doesn't need.
    cargoExtraArgs = "-p fortress-site";
    doCheck = false;
  };

  # ── server leg: native, deps cache shared with the fortress package ──
  serverArtifacts = nativeCraneLib.buildDepsOnly commonArgs;
  server = nativeCraneLib.buildPackage (commonArgs // {
    inherit cargoLock;
    cargoArtifacts = serverArtifacts;
  });

  # ── client leg: wasm32, own deps cache (different target = different
  #    objects), same source-change economics. The web tier has no
  #    server features — axum/tokio-net can't compile on wasm. ──
  wasmArgs = commonArgs // {
    CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
    cargoExtraArgs = commonArgs.cargoExtraArgs + " --no-default-features --features web";
  };
  wasmArtifacts = wasmCraneLib.buildDepsOnly wasmArgs;
  wasmClient = wasmCraneLib.buildPackage (wasmArgs // {
    cargoArtifacts = wasmArtifacts;
  });

  siteBundle = pkgs.runCommand "fortress-site-bundle-0.1.0" {
    passthru = {
      inherit server wasmClient wasmBindgenCli;
    };
    meta = with lib; {
      description = "Fortress site — dioxus fullstack bundle (SSR server + wasm client)";
      license = licenses.agpl3Plus;
      platforms = platforms.linux;
    };
  } ''
    mkdir -p $out/bin $out/public/wasm
    install -m 0555 ${server}/bin/fortress-site $out/bin/fortress-site
    # The server's default public dir is exe_dir/public — bridge the
    # layout so the exe-relative path needs no DIOXUS_PUBLIC_PATH.
    ln -s ../public $out/bin/public
    ${wasmBindgenCli}/bin/wasm-bindgen \
      --target web --out-dir $out/public/wasm \
      ${wasmClient}/bin/fortress-site.wasm
    cp ${src}/crates/site/public/index.html $out/public/index.html
  '';
in
  siteBundle
