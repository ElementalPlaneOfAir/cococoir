# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — consolidated Rust crate.
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
# Cargo.lock is committed; nixpkgs vendors deps from it (cargoLock).
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "cococoir";
  version = "0.1.0";

  src = ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # buildRustPackage names binaries after each src/bin basename
  # (`edge`, `client`). Rename to `cococoir-edge` / `cococoir-client`
  # so the systemd units in nix/nixos-modules/{edge,client}.nix find
  # a single, predictable name.
  postInstall = ''
    mv $out/bin/edge $out/bin/cococoir-edge
    mv $out/bin/client $out/bin/cococoir-client
  '';

  # Do not let buildRustPackage strip the test executable name; the
  # lib target produces no bin of its own. Strip the two renamed bins.
  doCheck = true;

  meta = with lib; {
    description = "Cococoir v2 — L4 TCP/UDP forwarder (edge and client binaries)";
    homepage = "https://github.com/ElementalPlaneOfAir/cococoir";
    license = licenses.agpl3Plus;
    mainProgram = "cococoir-edge";
    platforms = platforms.linux;
  };
}
