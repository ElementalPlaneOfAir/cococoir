# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Cococoir dashboard dev environment — a minimal NixOS evaluation
# whose only job is rendering the Dex config for local development.
# Nothing here ever boots; `apps.dashboard-dev` (flake.nix) takes
# `config.services.dex.configFile` and runs it next to a
# bacon-watched dashboard.
#
# Deviations from the VM (vmtest.nix), all deliberate:
#   - issuer is http://127.0.0.1:5556/dex — no TLS, no Caddy
#     (contract assertion satisfied via public = false)
#   - Dex DB path is relative ("dex.db"); the app script cd's into
#     the data dir first, so it persists across restarts at
#     ~/.local/share/cococoir/dev-dex.db
#   - dev-only static client for the dashboard, inline dev secret
{
  config,
  lib,
  ...
}: {
  imports = [
    (import ../nix/nixos-modules)
  ];

  system.stateVersion = "25.11";
  nixpkgs.hostPlatform = "x86_64-linux";

  cococoir = {
    baseDomain = "localhost";
    storage.enable = false;
  };

  cococoir.services.dex = {
    issuer = "http://127.0.0.1:5556/dex";
    public = false;
  };

  services.dex.settings = {
    staticClients = [{
      id = "cococoir-dashboard";
      name = "cococoir dashboard";
      secret = "dev-secret";
      redirectURIs = ["http://localhost:3000/auth/callback"];
    }];
    staticPasswords = [{
      email = "dev@cococoir.local";
      # bcrypt cost MUST be >= 10 (dex minimum) or login 500s with
      # "given hash cost = 5 does not meet minimum cost requirement = 10".
      # Regenerate with: mkpasswd -m bcrypt -R 10 password
      hash = "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W";
      username = "dev";
      userID = "3d85863c-910e-42ba-b5ea-0507593aca75";
      groups = ["admins"];
      preferredUsername = "dev";
    }];
    storage.config.file = lib.mkForce "dex.db";
  };
}
