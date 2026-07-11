# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — consolidated Go module.
#
# One module, two binaries:
#   bin/cococoir-edge   — VPS-side L4 forwarder
#   bin/cococoir-client — customer-box-side L4 forwarder
#
# Both wrap the same internal/forwarder package. The 225-line
# duplication of v0 is gone; per-IP binding, retry-with-backoff, and
# graceful shutdown all live in the shared package. See PLAN_2.md
# ADR-006 and the v0.5 PR 1 spec.
#
# stdlib-only: no go.mod deps, vendorHash = null.
{
  lib,
  buildGoModule,
}:
let
  version = "0.1.0";
in
buildGoModule {
  pname = "cococoir";
  inherit version;

  src = ./.;

  vendorHash = null;

  subPackages = [
    "cmd/edge"
    "cmd/client"
  ];

  # buildGoModule names binaries after each subpackage's basename
  # (`edge`, `client`). Rename to `cococoir-edge` / `cococoir-client`
  # so the systemd units in nix/nixos-modules/{edge,client}.nix find
  # a single, predictable name.
  postInstall = ''
    mv $out/bin/edge $out/bin/cococoir-edge
    mv $out/bin/client $out/bin/cococoir-client
  '';

  ldflags = [ "-s" "-w" ];

  meta = with lib; {
    description = "Cococoir v2 — L4 TCP/UDP forwarder (edge and client binaries)";
    homepage = "https://github.com/ElementalPlaneOfAir/cococoir";
    license = licenses.agpl3Plus;
    mainProgram = "cococoir-edge";
    platforms = platforms.linux;
  };
}
