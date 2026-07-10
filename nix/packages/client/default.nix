# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — Go client package.
#
# Runs on the customer box. Receives L4 traffic from cococoir-edge
# over the WireGuard tunnel and forwards to 127.0.0.1:<port> where
# the local Caddy terminates TLS. Pure L4, stdlib-only.
#
# v0: this is a deliberate copy of the edge package
# (nix/packages/edge/default.nix). v0.5 PR 1 will consolidate both
# into a single Go module with sub-packages.
{
  lib,
  buildGoModule,
}: let
  version = "0.1.0";
in
  buildGoModule {
    pname = "cococoir-client";
    inherit version;

    src = ./.;

    vendorHash = null;

    subPackages = ["."];

    # buildGoModule names binaries after the Go package basename
    # ("client" here, from the dir name). Rename to "cococoir-client"
    # so the systemd unit in nixos-modules/client.nix finds a single,
    # predictable name.
    postInstall = ''
      mv $out/bin/client $out/bin/cococoir-client
    '';

    ldflags = ["-s" "-w"];

    meta = with lib; {
      description = "Cococoir v2 client service — L4 TCP/UDP forwarder on the customer box";
      homepage = "https://github.com/ElementalPlaneOfAir/cococoir";
      license = licenses.agpl3Plus;
      mainProgram = "cococoir-client";
      platforms = platforms.linux;
    };
  }
