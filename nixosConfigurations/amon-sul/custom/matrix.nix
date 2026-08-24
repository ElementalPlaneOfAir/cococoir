# SPDX-License-Identifier: AGPL-3.0-or-later
#
# amon-sul userland service: matrix-synapse (Matrix homeserver).
#
# Per ADR-027 this is a plain NixOS module, not a cococoir factory
# service. It does not get a Caddy vhost, Dex OIDC, or a btrfs
# subvolume from the platform — those are the customer's to wire, or
# not. matrix-synapse is the nixpkgs module; this file only pins the
# settings that matter for this box.
#
# Deploy-time TODO (values unreadable from here — the legacy config
# repo is gone and /var/lib/matrix-synapse is mode 0700):
#   - settings.server_name must match the legacy homeserver's
#     server_name or every existing account/room breaks. Confirm it
#     before the first rebuild.
#   - The legacy box runs postgres for synapse. This module starts on
#     the nixpkgs sqlite default; pointing at the legacy postgres DB
#     (and its credentials) is a deploy-time decision.
{
  config,
  lib,
  pkgs,
  ...
}: {
  services.matrix-synapse = {
    enable = true;
    settings = {
      server_name = config.cococoir.baseDomain;
      public_baseurl = "https://matrix.${config.cococoir.baseDomain}";
      enable_registration = false;
      listeners = [
        {
          port = 8008;
          bind_addresses = ["127.0.0.1"];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {names = ["client" "federation"]; compress = false;}
          ];
        }
      ];
    };
  };

  services.caddy.virtualHosts."matrix.${config.cococoir.baseDomain}".extraConfig = ''
    reverse_proxy 127.0.0.1:8008
  '';
}
