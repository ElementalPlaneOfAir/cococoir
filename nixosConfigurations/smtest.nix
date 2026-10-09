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
# The fixture is `public = true`, so Caddy fronts Dex on :80; assert Dex
# directly on loopback and through Caddy (Host: example.com /dex). The QEMU
# port-forward can't reach loopback, so assert over ssh, from inside.
{
  inputs,
  cococoirSource,
  pkgs,
  ...
}: let
  devCreds = import ../nix/dev/dev-credentials.nix;
  fortressApply = import ../nix/system-manager/apply.nix {inherit pkgs;};
  fortressBootstrap = import ../nix/system-manager/bootstrap.nix {inherit pkgs;};

  # The magic folder's flake: a thin consumer of cococoir. It points at the
  # repo *source* by store path (the VM's store is shared with the host) and
  # reads the flat `config.nix` beside it — exactly the onbox magic-folder
  # shape (PLAN.md ADR-035). Editing config.nix here and re-running
  # fortress-apply is the decoupled update path: no nixos-rebuild.
  fortressConfig = pkgs.runCommand "fortress-magic-folder" {
    buildInputs = [pkgs.age pkgs.sops pkgs.openssl];
  } ''
    mkdir -p $out
    # Carry a full copy of the source inside the folder rather than pointing
    # at it by store path: a store path is an unrooted build input, and a GC
    # between apply and the next boot deletes it (seen 2026-10-06), leaving
    # the reboot's apply with nothing to build. A relative `path:` input lives
    # in the folder on the guest disk and survives — which is also what a
    # self-contained magic folder needs.
    cp -r ${cococoirSource} $out/cococoir-source
    chmod -R u+w $out/cococoir-source

    # Sealed inventory, generated at build: the fixture has to carry one
    # before the first apply, because sops is mandatory (secrets.nix) and
    # the platform never mints a credential at runtime. Mirrors what
    # fortress-bootstrap does on a real box.
    mkdir -p $out/secrets
    age-keygen -o $out/secrets/device.agekey 2>/dev/null
    pub=$(age-keygen -y $out/secrets/device.agekey)
    plaintext=$(mktemp)
    printf '%s: "%s"\n' fortress-admin-password-hash \
      '${devCreds.adminPasswordHash}' >> "$plaintext"
    ${builtins.concatStringsSep "\n" (builtins.map (k: ''
      printf '%s: "%s"\n' ${k} "$(openssl rand -hex 32)" >> "$plaintext"
    '') ["jellarr-api-key" "jellyfin-admin-password"
         "radarr-api-key" "sonarr-api-key" "seerr-admin-password" "cryptpad-jwt-secret"
         "oidc-jellyfin-secret" "oidc-cryptpad-secret" "oidc-forgejo-secret"])}
    sops --encrypt --age "$pub" --input-type yaml --output-type yaml "$plaintext" > "$out/secrets/secrets.enc.yaml"
    rm -f "$plaintext"
    cat > $out/flake.nix <<'FLAKE'
    {
      description = "fortress magic folder (smtest fixture)";
      inputs.cococoir.url = "path:./cococoir-source";
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
      # qemu's user-networking hands the guest 10.0.2.15 — the address the
      # LAN DNS plane answers with and every vhost binds (ADR-028).
      fortress.network.lanAddress = "10.0.2.15";
      # public = true pulls in Caddy — the applier's ingress. This fixture
      # deliberately exercises it: the dex-only (public = false) slice left
      # Caddy's identity + /etc gaps invisible until the amon-sul cutover
      # (2026-10-07). tls defaults to "off", so Caddy serves plain HTTP.
      fortress.secrets.sopsFile = ./secrets/secrets.enc.yaml;
      fortress.services.dex = {
        enable = true;
        public = true;
      };
    }
    CONFIG
  '';

in {
  imports = [
    "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
    ../nix/nixos-modules/applier.nix
  ];

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
  # fortress-apply is on PATH so the e2e can re-apply after editing config.nix;
  # dig is there so the e2e can query the LAN DNS plane from inside the box.
  environment.systemPackages = [pkgs.curl pkgs.dnsutils fortressApply fortressBootstrap];

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
  # The guest's writable store must be on the VM disk, not tmpfs. qemu-vm
  # defaults it to tmpfs, which silently discards everything built in-guest on
  # reboot and forces every boot to lean on paths the *host* built and rooted.
  # That is why the reboot step failed: the host's nix-gc.timer collected the
  # folder's unrooted store copy, and the guest — whose store had been wiped —
  # had nothing to fall back on. A real box has a persistent store; make the
  # test match reality.
  virtualisation.writableStoreUseTmpfs = false;
  virtualisation.diskSize = 4096;
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 2223;
      guest.port = 22;
    }
  ];

  # The ADR-035 half, dogfooded through `nixosModules.applier` (ADR-037):
  # fortress is built + applied from the magic folder at run time, OUTSIDE the
  # nixos-rebuild closure — exactly amon-sul's two-lifecycle shape. The module
  # installs the boot trampoline; a reboot re-applies because NixOS clears
  # /run/systemd/system.
  fortress.applier.enable = true;

  # Seed the fixture once. Activation runs before systemd, so the folder
  # exists by the time the applier's units are up, and the module's first-boot
  # generator is skipped (ConditionPathExists). This VM proves reboot
  # survival; the generator's own first-boot half is proven separately.
  system.activationScripts.fortressFixture = ''
    if [ ! -e /etc/fortress/config/flake.nix ]; then
      mkdir -p /etc/fortress/config
      cp -r ${fortressConfig}/. /etc/fortress/config/
      chmod -R u+w /etc/fortress/config
      # The device age key is the one thing outside the store and outside
      # the folder (see sops-wire.nix) — a real box keeps it at
      # /etc/fortress/system_age_keys.txt, written by fortress-bootstrap.
      install -m 0400 ${fortressConfig}/secrets/device.agekey \
        /etc/fortress/system_age_keys.txt
    fi
  '';
}
