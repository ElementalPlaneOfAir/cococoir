# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Fortress v2: NixOS + btrfs + services for the home-server product. AGPL-3.0-or-later.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
    sops-nix.url = "github:Mic92/sops-nix";
    # Declarative Jellyfin configuration (libraries, users,
    # plugin config, startup-wizard skip) via the official
    # Jellyfin REST API. The jellyfin service module activates
    # `services.jellarr` automatically when jellyfin is
    # enabled — customers never see jellarr as a separate
    # thing. Tracks main (no tag pin); the v0.1.0 tag fails
    # to evaluate on current nixpkgs.
    jellarr = {
      # Pinned to the unmerged Jellyfin-12 auth fix (upstream PR #79):
      # Jellyfin 12 (this lock's nixpkgs) requires the
      # `Authorization: MediaBrowser Token=...` header; main still
      # sends X-Emby-Token and crashes jellarr at runtime. Unpin to
      # upstream main when PR #79 merges.
      url = "github:venkyr77/jellarr/317f7be9d4a758f25b8180feb41fae12530a53a1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Manage the edge box on a stock Debian image: systemd services,
    # packages, and root-level config applied atomically with Nix,
    # without taking over the OS. The edge never needed full NixOS
    # (it's a stateless forwarder), and a stock image removes the
    # disko/fstab/NIC boot problems entirely. Customer boxes stay NixOS.
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Rust build library: splits `buildDepsOnly` (workspace deps, built
    # once + cached) from `buildPackage` (our crate, recompiled on
    # change) so a source edit doesn't rebuild every dependency.
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Weekly-built nix-index database (command name -> nixpkgs attrpath).
    # comma (nix-community) is a wrapper around `nix shell -c` + nix-index
    # and CANNOT resolve `, foo` without this index. We use its
    # `comma-with-db` package (the SMALL /bin-only database, ~1.7 MB, not
    # the 92 MB full one — headers/libs are nix-locate's domain, comma
    # only ever matches command names) via the overlay below, so every
    # fortress box gets a comma that actually works with zero setup.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...}@inputs: let
    # nixpkgs with the crane flake injected as an attribute, so any
    # `pkgs.callPackage ./nix/packages/fortress {}` (in the NixOS
    # modules, the tests, the edge systemConfig) resolves the `crane`
    # arg it now needs, without threading the flake input through every
    # call site.
    # The overlay list every fortress build shares — `crane` (so any
    # `pkgs.callPackage ./nix/packages/fortress {}` resolves its crane
    # arg), the jellarr fetchPnpmDeps hash substitution, and the
    # nix-index-database overlay. Used by BOTH `mkPkgs` (NixOS
    # consumers) and the system-manager configs (via `nixpkgs.overlays`)
    # so there is exactly one pkgs-shaping definition.
    fortressOverlays = [
      (final: prev: {
        crane = inputs.crane;
        # jellarr (rev 317f7be, PR #79's Jellyfin-12 auth fix) hardwires
        # a fetchPnpmDeps hash computed against an older nixpkgs
        # toolchain; the 2026-09-19 lock bump (ec2d622 -> e554fab)
        # changed what the fetcher produces. Substitute only when the
        # exact stale value flows through — upstream's own hash fix
        # (or a lock rollback) renders this inert. Load-bearing today:
        # 317f7be's nix/package.nix still carries the stale hash.
        fetchPnpmDeps = args:
          prev.fetchPnpmDeps (if args ? hash && args.hash
            == "sha256-jo1BjRAjjfNKF0xb5cLCuELSveHeJ98iLPhMDKP1QbI="
          then args // {
            hash = "sha256-qNVnhHjTFPhJxJ8oZPBSfJs2OjNSlbmS31okZuSGWMU=";
          } else args);
      })
      # nix-index-database overlay: adds `comma-with-db` (comma + the
      # small nix-index database wired via NIX_INDEX_DATABASE) to pkgs,
      # so every machine built with these pkgs gets a comma that can
      # actually resolve `, foo` -> attrpath. Without this, the raw
      # `comma` binary is a dead end (it has no database to look names
      # up in).
      inputs.nix-index-database.overlays.nix-index
    ];
    withCrane = system:
      import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = fortressOverlays;
      };
    vmtestPkgs = withCrane "x86_64-linux";
    vmtest = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      pkgs = vmtestPkgs;
      specialArgs = { inherit inputs; };
      modules = [
        ./nixosConfigurations/vmtest.nix
        "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        inputs.jellarr.nixosModules.default
        inputs.sops-nix.nixosModules.sops
      ];
    };

    # The customer box is the flake consumer's own NixOS machine — they
    # import `nixosModules.default` + `flake.lib.mkPkgs` into their home
    # server config (see remote-infra/README.md). No demo customer box is
    # rendered or exposed here.
    nixosModulesWithJellarr = {
      imports = [
        inputs.jellarr.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        ./nix/nixos-modules
      ];
    };

    # The fortress applier's input (ADR-035): turn a customer `config.nix`
    # (the magic folder's flat config module) into the system-manager config
    # the applier builds. This is the one entrypoint a magic-folder flake
    # calls — `cococoir.lib.mkFortressSystemConfig` — so the customer flake
    # stays a few lines. Mirrors `nixosModules.default`, but evaluated by
    # `makeSystemConfig` so fortress lands on the target's systemd OUTSIDE
    # `nixos-rebuild` (uniform NixOS / non-NixOS). Applied by
    # `fortress-apply`, not by `system-manager switch` (see
    # nix/system-manager/apply.sh for why).
    #
    # The overlays MUST flow through this function argument, not
    # `nixpkgs.overlays` (a module option). `nixpkgs.overlays` has type
    # `listOf anything`, and `types.anything` merges FUNCTION values
    # pointwise — that forces each overlay's output attrs while the pkgs
    # fixed point is still being built, so `final.callPackage` re-enters
    # (infinite recursion at nix-index-database's `comma-with-db`). The
    # function arg is concatenated raw (`overlays ++ cfg.overlays`),
    # preserving fixed-point laziness.
    mkFortressSystemConfig = config: let
      pkgs = import inputs.nixpkgs {
        system = "x86_64-linux";
        overlays = fortressOverlays;
        config.allowUnfree = true;
      };
      eval = inputs.nixpkgs.lib.evalModules {
        specialArgs = {
          inherit inputs;
          # `imports`/`disabledModules` may only reference specialArgs —
          # ordinary module args resolve through `config` and recurse.
          nixosModulesPath = "${inputs.nixpkgs}/nixos/modules";
        };
        modules =
          [
            config
            ./nix/system-manager/fortress.nix
            {
              # Overlays MUST NOT go through `nixpkgs.overlays`: its
              # `listOf anything` merges function values pointwise and
              # forces each overlay's output attrs while the pkgs fixed
              # point is still being built (infinite recursion at
              # nix-index-database's `comma-with-db`). Instantiate pkgs
              # here instead and hand it to the module system.
              # `nixpkgs.overlays` is `listOf anything` and merges function
              # values pointwise, which forces each overlay's output attrs
              # while the pkgs fixed point is still being built (infinite
              # recursion at nix-index-database's `comma-with-db`). Hand
              # `misc/nixpkgs.nix` a finished pkgs instance instead.
              nixpkgs.pkgs = pkgs;
            }
          ]
          ++ (import (inputs.nixpkgs + "/nixos/modules/module-list.nix"));
      };
      cfg = eval.config;
      inherit (inputs.nixpkgs) lib;
      enabledUnits = lib.filterAttrs (_: unit: unit.enable) cfg.systemd.units;
      # The applier installs ONLY fortress's units. The full NixOS module
      # set auto-enables host-OS units (getty@, serial-getty@, logrotate),
      # and writing those into /run/systemd/system would override the
      # host's own — exactly the class of fight ADR-035 forbids. So the
      # tree is the transitive `wants`/`requires` closure of
      # `fortress.target`, nothing else.
      #
      # `systemd.units` keys are full unit names ("x.service");
      # `systemd.services`/`targets`/... keys are bare ("x"). Normalize.
      unitKindSuffix = {
        services = ".service";
        targets = ".target";
        sockets = ".socket";
        timers = ".timer";
        mounts = ".mount";
        automounts = ".automount";
        paths = ".path";
        slices = ".slice";
      };
      unitKinds = builtins.attrNames unitKindSuffix;
      kindOf = kind: let u = cfg.systemd.${kind} or {}; in if builtins.isAttrs u then u else {};
      unitDeps = name:
        lib.unique (lib.concatMap (kind:
          let u = kindOf kind; base = lib.removeSuffix unitKindSuffix.${kind} name; e = u.${base} or {};
          in (lib.toList (e.wants or [])) ++ (lib.toList (e.requires or []))
        ) unitKinds);
      selfHung = lib.concatMap (kind:
        lib.mapAttrsToList (base: _: base + unitKindSuffix.${kind})
          (lib.filterAttrs (_: u:
            builtins.elem "fortress.target" (lib.toList (u.wantedBy or []) ++ lib.toList (u.requiredBy or []))
          ) (kindOf kind))
      ) unitKinds;
      closureOf = roots:
        let
          step = seen:
            let next = lib.filter (n: !(builtins.elem n seen)) (lib.concatMap unitDeps seen);
            in if next == [] then seen else step (seen ++ next);
        in step (lib.unique roots);
      roots =
        ["fortress.target"]
        ++ (lib.toList (cfg.systemd.targets.fortress.wants or []))
        ++ selfHung;
      wantedUnits = lib.filterAttrs (n: _: builtins.elem n (closureOf roots)) enabledUnits;
    in
      eval
      // {
        # Which units the applier installs — the `fortress.target` closure.
        # `applier-wiring` asserts against exactly this set.
        applierUnitNames = builtins.attrNames wantedUnits;
        # The rendered systemd unit tree — `fortress-apply` installs just
        # this into /run/systemd/system. Building it alone keeps the
        # applier decoupled from the OS closure (ADR-035).
        unitsDir = pkgs.runCommand "fortress-units" {} ''
          mkdir -p $out/systemd/system
          for u in ${toString (lib.mapAttrsToList (n: v: v.unit) wantedUnits)}; do
            ln -s $u/* $out/systemd/system/
          done
        '';
      };

    # Current vertical slice: dex (always-on OIDC infra) on loopback.
    # Used by `nix run .#system-manager -- switch --flake .#fortress`;
    # the runtime VM builds from the magic-folder fixture instead, to
    # prove the applier is decoupled from the OS closure.
    fortressSystemConfig = mkFortressSystemConfig ({...}: {
      nixpkgs.hostPlatform = "x86_64-linux";
      fortress.baseDomain = "example.com";
      # plain-dirs isolates the applier from btrfs's host-OS bits
      # (services.btrfs.autoScrub / boot.supportedFilesystems are
      # NixOS-only; a separate port concern).
      fortress.storage.backend = "plain-dirs";
      fortress.services.dex = {
        enable = true;
        # Loopback-only for this slice: `public = true` requires
        # Caddy to be wired (planes.nix), the next slice.
        public = false;
      };
    });

    # L1 fixture for the applier-wiring check: the same applier config but
    # with a *public* service, so Caddy (never enabled in the dex-only
    # slice above) is exercised. See nix/tests/applier-wiring/.
    applierPublicConfig = (mkFortressSystemConfig ({pkgs, ...}: {
      nixpkgs.hostPlatform = "x86_64-linux";
      fortress.baseDomain = "example.com";
      fortress.storage.backend = "plain-dirs";
      fortress.network.lanAddress = "10.0.2.15";
      # sops is mandatory (secrets.nix): a sealed inventory is the only
      # way secret material arrives. L1 only asserts the *wiring*, so the
      # ciphertext is a placeholder and its hash is not checked — real
      # decryption is proven at L2 (smtest) with real sops.
      sops.validateSopsFiles = false;
      fortress.secrets.sopsFile = pkgs.writeText "l1-test-secrets.yaml" ''
        fortress-admin-password-hash: ENC[PLACEHOLDER]
      '';
      fortress.services.dex = {
        enable = true;
        public = true;
      };
      fortress.services.jellyfin = {
        enable = true;
        public = true;
        mediaRoot = "/media/entertain";
      };
      services.fortress-client = {
        enable = true;
        settings.forwards = [
          {
            listen_addr = "{tunnel_ip}:8080";
            proto = "tcp";
            dest_addr = "127.0.0.1:80";
          }
        ];
      };
    }));

    # ADR-035 runtime-proof VM: NixOS owns the machine (boot + ssh), and a
    # boot trampoline runs `fortress-apply` against a magic-folder fixture on
    # disk — exactly amon-sul's two-lifecycle topology. The OS closure holds
    # only the applier + the fixture source, NEVER the fortress service
    # closure: `cococoirSource` is the repo *source* (text), which the VM
    # builds from at run time.
    smtest = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      pkgs = withCrane "x86_64-linux";
      specialArgs = {
        inherit inputs;
        cococoirSource = self.outPath;
      };
      modules = [./nixosConfigurations/smtest.nix];
    };
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake.nixosModules.default = nixosModulesWithJellarr;

      # The trampoline a *machine* flake imports (ADR-037): the ONLY fortress
      # surface on a NixOS host's own config. It deliberately does NOT import
      # the service stack — the applier builds that from the magic folder at
      # run time, outside the `nixos-rebuild` closure (ADR-035). Importing
      # `default` here instead is the coupling this exists to prevent.
      flake.nixosModules.applier = ./nix/nixos-modules/applier.nix;

      # The pkgs factory every consumer of `nixosModules.default`
      # must pass as `nixpkgs.pkgs`. The modules callPackage the
      # Rust client (which needs `crane`) and build jellarr's pnpm
      # deps (which need the hash substitution above) against the
      # system's pkgs — so a consumer using its own nixpkgs would
      # fail to build both. Exposing the factory keeps a customer
      # flake's pkgs wiring to one line instead of a copy of this
      # flake's internals.
      flake.lib.mkPkgs = withCrane;

      # The entrypoint a magic-folder `flake.nix` calls to turn the customer's
      # `config.nix` into the system-manager config the applier builds. Keeps
      # the customer flake to a few lines and the pkgs/overlay wiring in one
      # place.
      flake.lib.mkFortressSystemConfig = mkFortressSystemConfig;

      # The edge box is managed by system-manager on a stock Debian
      # image (not NixOS). systemConfigs.edge is the system-manager
      # config; the merged fortress-edge binary is injected via
      # extraSpecialArgs. Deploy with:
      #   nix run .#system-manager -- switch --flake .#edge
      flake.systemConfigs.edge = inputs.system-manager.lib.makeSystemConfig {
        modules = [./remote-infra/system-manager/edge.nix];
        specialArgs = {
          fortressEdgePkg = inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ./nix/packages/fortress {
            crane = inputs.crane;
          };
          # comma + its small nix-index database (NIX_INDEX_DATABASE wired),
          # so the operator's `, foo` debug tool resolves names on the box.
          commaWithDbPkg = inputs.nix-index-database.packages.x86_64-linux.comma-with-db;
        };
      };

      flake.systemConfigs.fortress = fortressSystemConfig;

      # Manual v2 dev VM: every fortress service under test, each
      # behind its own Caddy vhost in the `vmtest.local`
      # cookie-jar. Today that includes Jellyfin and Dex;
      # nextcloud, gitea, etc. land here as the service modules
      # come online. Run with:
      #   nix run .#vmtest
      #   # or headless: nix run .#vmtest -- -nographic
      # See nixosConfigurations/vmtest.nix for full docs.
      flake.nixosConfigurations.vmtest = vmtest;

      # ADR-035 runtime proof: NixOS + system-manager (amon-sul's topology).
      #   nix run .#smtest -- -nographic
      # then: curl http://127.0.0.1:5557/dex/.well-known/openid-configuration
      flake.nixosConfigurations.smtest = smtest;

      perSystem = {pkgs, self', system, ...}: let
        # Real nixpkgs for dev tooling. flake-parts' perSystem `pkgs`
        # come from a vendored nixpkgs fork (its `dex` is the
        # DesktopEntry launcher, not the OIDC provider), so service
        # binaries and config renders always come from here.
        realPkgs = inputs.nixpkgs.legacyPackages.${system};
        # Dev admin login for the dashboard: password = "password".
        # Generate a fresh one with `mkpasswd -m bcrypt -R 10 <pw>`.
        devAdminHash =
          "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W";
      in {
        checks = import ./nix/tests {
          inherit (withCrane system) pkgs;
          sopsModule = inputs.sops-nix.nixosModules.sops;
        }
        # vmtest is pinned to x86_64-linux; only wire its eval
        # tripwire into checks on that system.
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") (
          import ./nix/tests/vmtest-wiring {
            inherit (withCrane system) pkgs;
            vmtestConfig = vmtest.config;
            vmtestSystem = vmtest;
          }
          // import ./nix/tests/applier-wiring {
            inherit (withCrane system) pkgs;
            applierConfig = applierPublicConfig;
          }
        );
        # The app's `program` field is just a string path. We avoid
        # interpolation of `vmtest.config.system.build.vm` (which
        # flake-parts mishandles) by shelling out to `nix run` on
        # the nixosConfiguration attribute path. The nix run
        # re-evaluates the config and dispatches the vm's run
        # script.
        apps.vmtest = {
          type = "app";
          program = toString (pkgs.writeShellScript "vmtest-run" ''
            exec nix run .#nixosConfigurations.vmtest.config.system.build.vm -- "$@"
          '');
        };
        # Full-OS container demo tier (x86_64-linux only; the
        # nixosConfiguration exists only there). Builds the rootfs
        # tarball, imports it, and runs it: systemd as PID 1, Caddy on
        # the published :443, service data on a named host volume.
        # secretspec 0.19 CLI from the flake's locked nixpkgs. The
        # devshell's `secretspec` comes from devenv's own nixpkgs and is
        # an older version without the `file` provider backend, so the
        # provisioning scripts and this app are the pinned, canonical
        # entry point. Run from the repo root:
        #   nix run .#secretspec -- export -P provisioning -S token ...
        apps.secretspec = {
          type = "app";
          program = "${realPkgs.secretspec}/bin/secretspec";
        };
        # Dashboard live-edit loop + local edge, managed by
        # process-compose: bacon's dashboard job (admin login enabled),
        # a throwaway redis, and the edge in debug-only `--dummy` mode
        # (mock WG/DNS, console mailer, real HTTP/store wiring at
        # :8081), all torn down cleanly on Ctrl-C. Run from the repo
        # root:
        #   nix run .#dashboard-dev
        # The pc spec lives in nix/dev/process-compose.nix — dev
        # tooling, deliberately outside the nixos modules.
        apps.dashboard-dev = let
          devPcConfig = (realPkgs.formats.yaml {}).generate "dashboard-dev.yaml"
            (import ./nix/dev/process-compose.nix {
              pkgs = realPkgs;
              adminPasswordHash = devAdminHash;
            });
        in {
          type = "app";
          program = toString (realPkgs.writeShellScript "dashboard-dev" ''
            # TUI when attached to a terminal; -t=false keeps the
            # process tree managed the same way in headless runs.
            # --no-server: pc's web UI is unused and its 8080 binding
            # collides with anything else on that port.
            if [ -t 0 ]; then
              exec ${realPkgs.process-compose}/bin/process-compose --no-server -f ${devPcConfig}
            else
              exec ${realPkgs.process-compose}/bin/process-compose --no-server -t=false -f ${devPcConfig}
            fi
          '');
        };
      };
    };
}
