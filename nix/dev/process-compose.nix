# SPDX-License-Identifier: AGPL-3.0-or-later
#
# process-compose spec for the dashboard dev environment
# (`apps.dashboard-dev`). Deliberately NOT a nixos module and not part
# of the service contract — pure dev tooling, kept out of the main tree
# (the only file under nix/dev/). Serialized to YAML via the same
# `formats.yaml` the dex config uses.
#
# process-compose owns the process tree so Ctrl-C tears down dex AND
# bacon together. A bash trap can't do this: bacon runs under `script`,
# which puts it in its own session, out of reach of a `kill $pid`.
#
# Path assumptions: `nix run .#dashboard-dev` runs from the repo root,
# so `dashboard`'s `cd` is relative. `dex`'s `cd` keeps the per-user
# data dir out of the static spec (pc's `working_dir` does not expand
# `$HOME`). Both commands run through pc's default `/bin/sh`.
{
  dexPkgs,      # nixosSystem pkgs (real nixpkgs — perSystem pkgs are a fork)
  dexBinary,    # store path of the dex-oidc binary
  devDexConfig, # store path of the rendered dev Dex config
}:
{
  processes = {
    dex = {
      command = ''
        cd "''${XDG_DATA_HOME:-''$HOME/.local/share}/cococoir" && exec ${dexBinary} serve ${devDexConfig}
      '';
      readiness_probe = {
        http_get = {
          host = "127.0.0.1";
          port = 5556;
          path = "/dex/.well-known/openid-configuration";
        };
        initial_delay_seconds = 1;
        period_seconds = 1;
      };
    };
    dashboard = {
      command = ''
        cd nix/packages/cococoir && exec ${dexPkgs.util-linux}/bin/script -qec "${dexPkgs.bacon}/bin/bacon dashboard" /dev/null
      '';
      depends_on = {
        dex = {
          condition = "process_healthy";
        };
      };
      environment = {
        COCOCOIR_OIDC_ISSUER = "http://127.0.0.1:5556/dex";
        COCOCOIR_OIDC_CLIENT_ID = "cococoir-dashboard";
        COCOCOIR_OIDC_CLIENT_SECRET = "dev-secret";
      };
    };
  };
}
