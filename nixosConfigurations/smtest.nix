# SPDX-License-Identifier: AGPL-3.0-or-later
#
# smtest — the ADR-035 runtime-proof VM.
#
# NixOS owns the MACHINE (boot, disk, ssh) via nixos-rebuild. Fortress is
# built and applied at RUN TIME by `fortress-apply` from the magic folder on
# disk — the NixOS closure below holds only the applier and the fixture
# *source*, never the fortress service closure. That is the decoupling
# ADR-035 promises and amon-sul needs: changing `config.nix` and re-running
# `fortress-apply` never touches nixos-rebuild.
#
# Boot:    nix run .#smtest -- -nographic
# Assert:  ssh -p 2223 root@localhost \
#            'curl -sf http://127.0.0.1:5556/dex/.well-known/openid-configuration'
# (dex binds loopback — `public = false` in this slice — so the QEMU
# port-forward can't reach it; assert over ssh, from inside.)
{
  inputs,
  cococoirSource,
  pkgs,
  ...
}: let
  fortressApply = import ../nix/system-manager/apply.nix {inherit pkgs;};

  # The magic folder's flake: a thin consumer of cococoir. It points at the
  # repo *source* by store path (the VM's store is shared with the host) and
  # reads the flat `config.nix` beside it — exactly the onbox magic-folder
  # shape (PLAN.md ADR-035). Editing config.nix here and re-running
  # fortress-apply is the decoupled update path: no nixos-rebuild.
  fortressConfig = pkgs.runCommand "fortress-magic-folder" {} ''
    mkdir -p $out
    cat > $out/flake.nix <<'FLAKE'
    {
      description = "fortress magic folder (smtest fixture)";
      inputs.cococoir.url = "path:${cococoirSource}";
      outputs = {cococoir, ...}: {
        systemConfigs.fortress =
          cococoir.lib.mkFortressSystemConfig (import ./config.nix);
      };
    }
    FLAKE
    cat > $out/config.nix <<'CONFIG'
    {...}: {
      nixpkgs.hostPlatform = "x86_64-linux";
      fortress.baseDomain = "example.com";
      fortress.storage.backend = "plain-dirs";
      fortress.services.dex = {
        enable = true;
        public = false;
      };
    }
    CONFIG
  '';

  # Seed the magic folder once (first boot), then apply it. A later boot keeps
  # any runtime edits — the folder is a real directory on the root fs, and
  # NixOS only clears /run. This mirrors the onbox flow where the folder is
  # the durable, user-edited app config.
  seedAndApply = pkgs.writeShellApplication {
    name = "fortress-seed-and-apply";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      if [ ! -e /etc/fortress/config/flake.nix ]; then
        mkdir -p /etc/fortress/config
        cp -r ${fortressConfig}/. /etc/fortress/config/
        chmod -R u+w /etc/fortress/config
      fi
      exec ${fortressApply}/bin/fortress-apply /etc/fortress/config
    '';
  };
in {
  imports = ["${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"];

  system.stateVersion = "25.05";
  networking.hostName = "smtest";

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };
  users.users.root.password = "password";
  # fortress-apply is on PATH so the e2e can re-apply after editing config.nix.
  environment.systemPackages = [pkgs.curl fortressApply];

  # The applier shells out to `nix build`. The VM store is an overlay over the
  # host store, so the magic folder's inputs (nixpkgs, system-manager, ...)
  # resolve from what the host already built.
  nix.settings.experimental-features = ["nix-command" "flakes"];

  virtualisation.memorySize = 4096;
  # Direct-boot VM sharing the host Nix store (read-only lowerdir, writable
  # overlay). The e2e pre-builds the fortress closure on the host, so the
  # applier's run-time build is a no-op and only the edited-config delta is
  # written. Without store sharing the VM would download and rebuild
  # system-manager's Rust pieces from source on every boot.
  virtualisation.mountHostNixStore = true;
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 2223;
      guest.port = 22;
    }
  ];

  # The ADR-035 half: fortress is built + applied by `fortress-apply` from the
  # magic folder at run time, OUTSIDE the nixos-rebuild closure — exactly
  # amon-sul's two-lifecycle shape. The trampoline seeds the folder once, then
  # applies; a reboot re-applies (NixOS clears /run/systemd/system).
  systemd.services.fortress-apply = {
    description = "ADR-035: apply fortress from the magic folder";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${seedAndApply}/bin/fortress-seed-and-apply";
    };
  };
}
