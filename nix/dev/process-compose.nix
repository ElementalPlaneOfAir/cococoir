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
        "FORTRESS_ADMIN_PASSWORD_HASH=${adminPasswordHash}"
        # The workspace is at the repo root, so the dashboard-edited
        # Nix config sits at ./nixosConfigurations/dashboard.nix.
        "FORTRESS_CONFIG_PATH=./nixosConfigurations/dashboard.nix"
      ];
    };
    # A throwaway Redis for the local edge. No persistence — the edge
    # only needs it as a live store while the dev box is up.
    redis = {
      command = "${pkgs.redis}/bin/redis-server --save \"\" --appendonly no";
    };
    # The edge in dummy mode (`--dummy`, a debug-builds-only flag): mock
    # WG/DNS, console mailer, real forwarder + Redis store + HTTP wiring.
    # Waits for redis to answer PING before booting (init fails fast
    # otherwise), then `cargo run`s the debug binary so a source edit is
    # picked up on the next bring-up. UI at http://localhost:8081.
    #
    # The `exec` line must stay on ONE physical line: process-compose
    # runs commands through its own embedded shell, which mishandles
    # backslash-newline continuations (it turns the trailing `\` into a
    # stray `n` argument).
    edge = {
      command = ''
        for i in $(seq 1 30); do
          ${pkgs.redis}/bin/redis-cli ping >/dev/null 2>&1 && break
          sleep 1
        done
        exec ${pkgs.cargo}/bin/cargo run --quiet --bin fortress-edge -- --dummy --subnet fd00::/64 --wg-subnet 10.10.0.0/24 --redis-url redis://127.0.0.1:6379 --api-addr 0.0.0.0:8081
      '';
    };
    # The site crate (landing, /docs wiki, /install.sh) on 8082.
    # Plain axum + dioxus SSR; independent of the edge's Redis.
    site = {
      command = ''
        exec ${pkgs.cargo}/bin/cargo run --quiet --bin fortress-site
      '';
    };
  };
}
