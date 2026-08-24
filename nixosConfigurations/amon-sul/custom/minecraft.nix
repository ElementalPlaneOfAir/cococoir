# SPDX-License-Identifier: AGPL-3.0-or-later
#
# amon-sul userland service: Minecraft server ("anarchy"). Plain NixOS
# module per ADR-027. nixpkgs' services.minecraft-server, world kept at
# the legacy location /srv/minecraft/anarchy.
{
  config,
  lib,
  pkgs,
  ...
}: {
  services.minecraft-server = {
    enable = true;
    eula = true;
    declarative = true;
    dataDir = "/srv/minecraft/anarchy";
    serverProperties = {
      server-port = 25565;
      motd = "amon-sul anarchy";
      online-mode = false;
      white-list = false;
    };
  };
}
