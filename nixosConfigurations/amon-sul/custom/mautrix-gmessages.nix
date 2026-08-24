# SPDX-License-Identifier: AGPL-3.0-or-later
#
# amon-sul userland service: mautrix-gmessages (Google Messages ↔
# Matrix bridge). Plain NixOS module per ADR-027.
#
# DEFERRED: nixpkgs ships the `mautrix-gmessages` package (26.05) but
# no `services.mautrix-gmessages` NixOS module. Wiring it is a
# systemd unit around `pkgs.mautrix-gmessages` plus an appservice
# registration whose shared secret lives in the legacy homeserver's
# mode-0700 dir. Completed at deploy time, when that config is
# readable. The legacy unit was:
#
#   ExecStart = ${mautrix-gmessages}/bin/mautrix-gmessages \
#                 /var/lib/mautrix-gmessages/config.yaml
{
  config,
  lib,
  pkgs,
  ...
}: {}
