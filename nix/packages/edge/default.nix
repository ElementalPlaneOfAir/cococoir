# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Go edge package.
#
# Pure-L4 TCP/UDP forwarder. stdlib-only; no Go module dependencies,
# so `vendorHash = null` (no vendor directory needed).
{
  lib,
  buildGoModule,
}: let
  version = "0.1.0";
in
  buildGoModule {
    pname = "cococoir-edge";
    inherit version;

    src = ./.;

    # No external Go deps; no vendor directory.
    vendorHash = null;

    subPackages = ["."];

    # buildGoModule names binaries after the Go package basename ("edge"
    # here, from the dir name). Rename to "cococoir-edge" so the systemd
    # unit in nixos-modules/edge.nix finds a single, predictable name.
    postInstall = ''
      mv $out/bin/edge $out/bin/cococoir-edge
    '';

    ldflags = ["-s" "-w"];

    meta = with lib; {
      description = "Cococoir v2 edge service — L4 TCP/UDP forwarder";
      homepage = "https://github.com/ElementalPlaneOfAir/cococoir";
      license = licenses.agpl3Plus;
      mainProgram = "cococoir-edge";
      platforms = platforms.linux;
    };
  }