# SPDX-License-Identifier: AGPL-3.0-or-later
{
  pkgs,
  stdenv,
  fetchzip,
}:
stdenv.mkDerivation {
  pname = "jellyfin-plugin-oidc-rbac";
  version = "1.0.8";

  src = fetchzip {
    url = "https://github.com/Ezeqielle/jellyfin-plugin-oidc/releases/download/v1.0.8/oidc-rbac.zip";
    hash = "sha256-qZ50uaVVQ0A4BFEVuPqldT3nN30P4gPZTDheW1up52I=";
    stripRoot = false;
  };

  installPhase = ''
    mkdir -p $out
    cp *.dll $out/
  '';
}
