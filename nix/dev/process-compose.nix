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
  # wasm hydration-client tooling (the siteBundle package's passthru),
  # ONLY when the site bundle exists for this system (x86_64-linux).
  # Null elsewhere — macOS has no siteBundle, so the wasm build step is
  # skipped and the site serves SSR-only (same as before this wiring).
  siteWasmToolchain ? null, # rust toolchain carrying the wasm32 std
  siteWasmBindgenCli ? null, # wasm-bindgen CLI, pinned to Cargo.lock
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
    # The site crate (landing, /docs wiki, /install.sh) on 8082. Runs
    # `--dummy` like the edge: the site embeds the control plane, and
    # without --dummy it reads boot secrets (secretspec CWD-walk from the
    # repo root hits the merged manifest — which is fine — but demands
    # /etc/fortress/edge.env, which a dev box doesn't have). Dummy =
    # DUMMY_ROOT_DOMAIN + console mailer + no secret resolution.
    #
    # The site's SSR router also serves the wasm hydration client from
    # `exe_dir/public` (serve_static_assets). The server leg alone can't
    # produce it — `cargo run` compiles only native — so site-wasm builds
    # it into `target/debug/public/wasm` (the exe's public dir) the same
    # way the nix bundle does, and `site` waits for it.
    site = {
      command = ''
        for i in $(seq 1 30); do
          ${pkgs.redis}/bin/redis-cli ping >/dev/null 2>&1 && break
          sleep 1
        done
        exec ${pkgs.cargo}/bin/cargo run --quiet --bin fortress-site -- --dummy
      '';
    } // (if siteWasmToolchain == null then {} else {
      depends_on = {
        "site-wasm" = { condition = "process_completed_successfully"; };
      };
    });
    # Build the wasm hydration client into the site server's public dir.
    # Mirrors the nix bundle's client leg exactly: `cargo build --target
    # wasm32-unknown-unknown` (web features only — axum can't compile on
    # wasm) + `wasm-bindgen --target web`. Without this the browser loads
    # index.html but 404s /wasm/* ("blocked because of a disallowed MIME
    # type") and hydration silently never happens. Rebuilds on source
    # change via the same `cargo run`-picks-up-edits cadence (this process
    # exits after building; site restarts see the fresh wasm).
  } // (if siteWasmToolchain == null then {} else {
    site-wasm = {
      command = ''
        mkdir -p target/debug/public/wasm && exec ${siteWasmToolchain}/bin/cargo build --quiet --target wasm32-unknown-unknown -p fortress-site --no-default-features --features web && ${siteWasmBindgenCli}/bin/wasm-bindgen --target web --out-dir target/debug/public/wasm target/wasm32-unknown-unknown/debug/fortress-site.wasm
      '';
    };
  });
}
