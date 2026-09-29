{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  # https://devenv.sh/basics/
  env.GREET = "devenv";
  dotenv.enable = true;

  # rust-overlay so `rust-bin` exists in the shell's pkgs. Pinned in
  # devenv.yaml (the flake itself no longer carries rust-overlay — the
  # only consumer was the deleted dioxus/wasm site bundle).
  overlays = [(import inputs.rust-overlay)];

  # https://devenv.sh/packages/
  packages = with pkgs; [
    opentofu
    nixos-anywhere
    wireguard-tools
    valkey
    # The site crate is edition 2024 and topcoat requires rustc >= 1.98;
    # nixpkgs' default rustc is 1.98.1 too, so the shell and the nix
    # build agree. No wasm target — nothing compiles to wasm anymore.
    (rust-bin.stable."1.98.1".default.override {
      extensions = ["rust-src" "rust-analyzer" "clippy" "rustfmt"];
    })
  ];

  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/scripts/
  scripts.hello.exec = ''
    echo hello from $GREET
  '';

  # https://devenv.sh/basics/
  enterShell = ''
    hello         # Run scripts directly
    git --version # Use packages
  '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"
  '';

  # https://devenv.sh/git-hooks/
  # git-hooks.hooks.shellcheck.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
