# SPDX-License-Identifier: AGPL-3.0-or-later
#
# process-compose spec for the dashboard dev environment
# (`apps.dashboard-dev`). Deliberately NOT a nixos module and not part
# of the service contract — pure dev tooling, kept out of the main tree
# (the only file under nix/dev/). Serialized to YAML via the same
# `formats.yaml` the dex config uses.
#
# process-compose owns the process tree so Ctrl-C tears down the whole
# bacon session (script → bacon → cargo → rustc). A bash trap can't do
# this: bacon runs under `script`, which puts it in its own session, out
# of reach of a `kill $pid`.
#
# Path assumption: `nix run .#dashboard-dev` runs from the repo root,
# so `dashboard`'s `cd` is relative. The command runs through pc's
# default `/bin/sh`.
{
  pkgs,             # real nixpkgs — perSystem pkgs are a vendored fork
  adminPasswordHash, # dev bcrypt hash (cost >= 10) for the admin login
}:
{
  processes = {
    dashboard = {
      command = ''
        exec ${pkgs.util-linux}/bin/script -qec "${pkgs.bacon}/bin/bacon dashboard" /dev/null
      '';
      environment = [
        "COCOCOIR_ADMIN_PASSWORD_HASH=${adminPasswordHash}"
        # The workspace is at the repo root, so the dashboard-edited
        # Nix config sits at ./nixosConfigurations/dashboard.nix.
        "COCOCOIR_CONFIG_PATH=./nixosConfigurations/dashboard.nix"
      ];
    };
  };
}
