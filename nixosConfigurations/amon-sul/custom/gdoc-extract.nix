# SPDX-License-Identifier: AGPL-3.0-or-later
#
# amon-sul userland service: gdoc-extract (Google Docs extractor — a
# self-built binary serving a static app on 127.0.0.1:8080).
#
# BLOCKED: the gdoc-extract source is not in this repo and the legacy
# config repo (which built it) is gone. The running binary exists only
# as a nix-store path (gdoc-extract-0.1.0). Add the package build (a
# path/flake input or overlay) and a systemd unit here once the source
# is available; the legacy unit was:
#
#   ExecStart = ${gdoc-extract}/bin/gdoc-extract -bind=127.0.0.1 -port=8080
#   WorkingDirectory = ${gdoc-extract}/share/gdoc-extract
{
  config,
  lib,
  pkgs,
  ...
}: {}
