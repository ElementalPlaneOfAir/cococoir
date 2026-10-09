# Status

Where the project is *right now*. The living layer of the docs —
PLAN.md says what we're building, this file says what actually
works today. Rules (from AGENTS.md § Context System):

- Every "works" claim names its proof (an L1 check or an e2e run).
  Claims without proof are debt.
- Update this file in the same commit that changes reality.
- Stay under ~80 lines. History belongs in `git log`.

Last e2e: PASS — 2026-10-08 — 8aedf1b
Last smtest e2e: PASS — 2026-10-08 — working tree (sealed secrets decrypt at boot)
(`scripts/vmtest-e2e.sh` rewrites this line on PASS.)

## Current focus

**A service is a config line, not a code change (2026-10-09, ADR-039).**
The applier now evaluates nixpkgs' **full** `module-list.nix` and installs
only the `fortress.target` closure. `host-shim.nix` is deleted. Root cause
of the old shape: system-manager reimplements NixOS *core* (`systemd`,
`users`, `firewall`, `ssh`, `boot`, `nixpkgs`, `logrotate`) and declares
those options as leaf stubs — the module system forbids an option and
nested options at the same path, so every nixpkgs service module had to be
imported one at a time ("graduated") behind a stub. Fix: drop
system-manager's module layer entirely; `lib.evalModules` against the real
module list, and fortress owns the unit extraction (`unitsDir` is the
transitive `wants`/`requires` closure of `fortress.target`, so the host's
own `getty@`/`logrotate` are never overwritten). Consequences proven in
`applier-wiring`: `fortress.services.jellyfin.enable = true` resolves
nixpkgs' jellyfin module and lands `jellyfin.service` in the applier
closure — **asserted**, and negative-tested.
Also fixed: `fortress-client` and `fortress-plain-dirs` hung off
`multi-user.target`, which the applier never starts — so they were
installed and never ran (latent on amon-sul). They now hang off
`fortress.target`.
**Proof:** `nix flake check` all pass (incl. `applier-wiring` with jellyfin
enabled, `vmtest-wiring`, `systemManagerWiring`, `bootstrapInventory`, the
edge VM tests). `systemManagerWiring` now fails if `host-shim.nix` returns.

**Secret material is sealed ciphertext in the store — one mechanism, no
runtime minting (2026-10-08, ADR-038).** Previously every credential was
minted at first boot (`openssl rand`, idempotent) and kept in `/var/lib`,
which solved store-leakage by giving up determinism: a rebuild rotated
every key and silently broke the integrations holding the old one. Now
`fortress-bootstrap` mints each inventory key **once**, seals it to the
device age key, and the platform reads `/run/secrets/<name>`.
`fortress.secrets.sopsFile` is required; `sops-wire.nix` is the only
place secret material is declared. The applier trap this fixed: sops-nix
falls back to `system.activationScripts` (a **no-op stub** under
system-manager) unless `useSystemdActivation` is forced, so a secret
would evaluate cleanly and decrypt *nothing* — `applier-wiring` now
asserts the unit path and that it precedes `fortress.target`.
`sops-wire.nix` was also dead code on the applier path entirely (imported
only by `nixosModulesWithJellarr`); it now lives in the shared
aggregator so every entry point gets it.
**Proof:** `scripts/smtest-e2e.sh` PASS with a new assertion —
`/run/secrets/{fortress-admin-password-hash,jellarr-api-key,radarr-api-key}`
populated at boot under the applier; `applier-wiring` PASS; `vmtest-wiring`
PASS (and it fails if a minting oneshot returns); `bootstrapInventory` PASS
(verified it fires on a removed key); `nix flake check` PASS.

**Proven on the real box (2026-10-09, amon-sul @ cococoir `92dc01b`).**
All 10 inventory keys decrypted to `/run/secrets/` at boot under the
applier; `sops-install-secrets` `Result=success` and ordered into
`fortress.target`; `fortress-plain-dirs` created the `/media` tree.
Dex serves on both planes (`/dex/auth` → 302 local, discovery → 200).
Still 502: `http://amon-sul/` — `fortress-client` is disabled in the box's
config (the tunnel identity is not registered with the edge yet), so the
dashboard has nothing to proxy to.

**Operational trap found on that deploy: the on-box `fortress-bootstrap`
is pinned to whatever rev *installed* it.** The units built at `8aedf1b`
shipped the old 4-key generator; running it to "regenerate all the keys"
minted 4 of 10 and would have failed `sops-install-secrets` at apply
time. The generator must be run from the rev that defines the inventory —
`scp` the script from the checkout being deployed, not the one the box
already has. The save was the mechanism itself: `sops.secrets` declares
the whole inventory, so a short sealed file fails loudly at install
rather than booting with credentials missing.

**Store-path config for every unit (2026-10-08, `applier-store-path-config`).**
The applier installs units only, so a unit's inputs must be store paths —
the dashboard 502 was `fortress-client` reading `/etc/fortress-client.json`,
which the applier never writes. Client config is now a `settings` attrset
rendered to a store path; `plain-dirs` is a systemd oneshot rather than
`systemd.tmpfiles.rules` (which the applier never applies). The
applier-surface is enforced positively in `applier-wiring`: no tmpfiles
beyond system-manager's baseline, no service referencing `/etc` (except
the sops age key), every config a store path. OIDC client secrets also
moved off `/etc/dex/clients/*` (which tmpfiles was supposed to create)
onto sops paths.
**Proof:** `applier-wiring` PASS, `vmtest-wiring` PASS, `vmtest-e2e` PASS
(client boots, dashboard serves), `nix flake check` PASS.

**Caddy now works under the applier — the amon-sul cutover can serve a
public service.** Fixed 2026-10-07, after the first cutover died on
`caddy.service: status=217/USER`. Two applier gaps, both specific to
Caddy: (1) upstream's module declares a `caddy` account the applier cannot
create (userborn disabled, ADR-036), and (2) it reads its config from
`/etc/caddy/caddy_config`, which `apply.sh` never installs. Fixed in
`nix/system-manager/fortress.nix`: Caddy runs as **root** (ADR-036 allows
it; `serviceConfig` cannot be cleared to DynamicUser), `HOME` points at
its StateDirectory (upstream's `ProtectHome` hides `/root`), and
`ExecStart`/`ExecReload` read the store-rendered Caddyfile, not `/etc`.
**Proof:** `scripts/smtest-e2e.sh` PASS — Caddy active, Dex reachable
through it on the LAN plane (`http://10.0.2.15/dex`), and back after a
reboot; plus the new `applier-wiring` L1 check.

**Caddy binds the wildcard (2026-10-07, `caddy-wildcard-bind`).** Every
fortress vhost now binds `0.0.0.0 ::` instead of localhost+LAN, so the
tailnet is a path and a new interface needs no config edit — the explicit
list bound localhost only when `lanAddress` was unset, exactly the amon-sul
cutover failure. Bare wildcard with **no** `remote_ip` allowlist is
deliberate short-term debt (ADR-034 amendment; allowlist next few
releases). The tunnel forwarder no longer contends for `:80`/`:443` on the
tunnel IP: the control plane's `EDGE_FORWARDS` binds the public port on the
customer `/128` and forwards to a distinct client port (`:8080`/`:8443`).
**Proof:** `smtest-e2e` PASS (Caddy serves the LAN plane, survives reboot),
`edge-forward` PASS (public `:80` → client `:8080` → app `:80`),
`vmtest-wiring` PASS (every vhost binds the wildcard), L0
`edge_forwards_decouple_public_and_client_ports`.

**HTTPS is scoped to the clearnet hostnames (2026-10-08, `https-scoping`).**
Caddy's default `auto_https` blankets *every* host on `:80` with a 308 to a
certless HTTPS origin, so `http://<machine-hostname>` (e.g. `http://amon-sul`)
bounced to `https://amon-sul` and died. Now `auto_https disable_redirects` is
set, each clearnet hostname gets an explicit `http://<host>` →
`https://<host>` 308, and the LAN plane is a `:80` catch-all serving plain
HTTP for any host, its Caddy origin tracking the request host so dex's issuer
and the callback swaps stay on the typed host (`fortress.planes.lanOrigin`
stays the LAN IP for OIDC callbacks). **Proof:** `vmtest-wiring` PASS (blanket
redirect disabled, every clearnet hostname redirects, LAN plane is a `:80`
catch-all), `nix flake check` PASS.

**The applier's surface is now enforced (2026-10-08, `applier-store-path-config`).**
The applier installs units only (`apply.sh`), so a module expressing an effect
via `environment.etc` / `systemd.tmpfiles.rules` lost it silently and the unit
died at boot — the dashboard 502. Now `fortress-client`'s config is a **store
path** passed to `-config` (never `/etc`), `plain-dirs` creates its data dirs
from a **systemd unit** (mirroring `fortress-btrfs-subvolumes`), not tmpfiles,
and the sole non-store reach is the sops age key. `applier-wiring` enforces the
surface: no tmpfiles beyond system-manager's baseline, no service referencing
`/etc` except the age key, every config a store path. **Proof:** `applier-wiring`
PASS, `vmtest-wiring` PASS, `vmtest-e2e` PASS (client boots, dashboard serves),
`nix flake check` PASS; ADR-035 amendment. The applier-path dashboard is proven
on the amon-sul box (client enabled + serving), not in-VM — the client is a
local Rust build and smtest deliberately never builds the service closure.

**Still blocked: the rest of amon-sul's services.** The applier imports
only `dex.nix` + `caddy/default.nix`; `host-shim.nix` stubs
`cryptpad/forgejo/jellyfin/qbittorrent/radarr/seerr/sonarr` with a hard
`!enable` assertion, and `jellarr` is OS-path only. Separately, `apply.sh`
installs only `systemd/system`, so `environment.etc` + `tmpfiles.d` are
never applied — the tunnel client's `/etc/fortress-client.json` cannot be
delivered, so `fortress-client` still cannot run under the applier.

**The cutover is staged and ready**, procedure in
`limonene/archive/amon-sul/DEPLOY.md`: the applier is committed+pushed
(cococoir `a3c5fad`), and the machine flake + folder seed are on the box
at `/home/nicole/amon-sul-deploy/`. Gates on the live run: the box's DNS
is broken (tailscale MagicDNS resolves no public names → `github.com`/
`cache.nixos.org` unreachable) and there is no passwordless sudo, so
bootstrap + `nixos-rebuild switch` + reboot must be run by a human.

Known limit, accepted (ADR-037, option 2): the applier roots its build
**output**, not the folder's flake **inputs**, so an offline reboot works
on a default box (`nix.gc.automatic = false`) but not after a GC.

<!-- AUTO-STATUS:BEGIN (regenerated by scripts/status.sh — do not hand-edit) -->
Regenerated: 2026-10-07T23:32:27Z — git 6fcf25b
- `doc-refs` — PASS
- `contract-conformance` — PASS
- `vmtest-wiring` — PASS
- `systemManagerWiring` — PASS
- `applierTrampoline` — PASS
- `applier-wiring` — PASS
- `provisioning-store` — PASS
- `secrets-hygiene` — PASS
- `src-filter-covers-includes` — PASS
<!-- AUTO-STATUS:END -->

- **The applier trampoline — one-line machine flake + reboot survival
  (2026-10-06)** — ADR-035 decided the applier but nothing on a NixOS
  host *ran* it, and the applier installs into tmpfs
  `/run/systemd/system`, so fortress died on every reboot. New
  `nixosModules.applier` (what a *machine* flake imports; contains only
  the trampoline, never the service stack) installs two oneshots:
  `fortress-bootstrap` (first boot only, `ConditionPathExists`) then
  `fortress-apply` (`wantedBy = multi-user.target`, every boot).
  **Proof:** `scripts/smtest-e2e.sh` E2E PASS 6/6 — step 6 `reboot` →
  Dex back on :5557 with no manual apply, plus an on-box
  `fortress-bootstrap` layout/idempotency check. `scripts/status.sh` 5/5
  via the new `applierTrampoline` tripwire. Boundary written as
  **PLAN.md ADR-037** — the ADR `onbox-config-secrets` promised and
  never wrote; the folder is an app layer on every target and the
  machine flake's only fortress surface is `fortress.applier.enable`.

  Also: `apply.sh` now roots its build under
  `/nix/var/nix/gcroots/fortress-apply` (it used `--no-link`, so the
  unit tree was collectible) — **output only**; inputs stay option-2 as
  ADR-037 records. Test scaffolding: smtest's writable store defaulted
  to tmpfs, so the guest rebuilt from scratch every boot and leaned on
  unrooted host paths (the host runs `nix-gc.timer`); fixed with
  `writableStoreUseTmpfs = false` + a registered gcroot for the fixture.

- **Caddy runs under the applier (2026-10-07)** — the first real cutover
  (amon-sul) died on `caddy.service: status=217/USER`: upstream's caddy
  module declares a `caddy` account the applier cannot create, and reads
  its config from `/etc/caddy/caddy_config`, which `apply.sh` never
  installs. Fixed in `nix/system-manager/fortress.nix` — Caddy runs as
  **root** (ADR-036; `serviceConfig` cannot be nulled to DynamicUser),
  `HOME` points at its StateDirectory (upstream's `ProtectHome` hides
  `/root`), and `ExecStart`/`ExecReload` read the store-rendered Caddyfile
  (the staticEnv still carries `/etc/caddy/caddy_config`, inert — apply.sh
  installs only `systemd/system`). **Proof:** `scripts/smtest-e2e.sh` PASS
  — Caddy active, Dex proxied on the LAN plane (`http://10.0.2.15/dex`),
  survives re-apply + reboot; new `applier-wiring` L1 check pins all four.
  The smtest fixture was `dex.public = false`, so Caddy was never enabled
  on the applier path — that masking gap is closed (fixture now public).

- **ADR-035 applier — dex vertical slice, decoupled (2026-10-05)** — the
  applier (`nix/system-manager/{fortress.nix,apply.nix,apply.sh}` +
  `flake.lib.mkFortressSystemConfig`) runs fortress's whole module tree
  under `makeSystemConfig` and applies it to the host's systemd WITHOUT
  `system-manager switch` — which is unsafe on NixOS (its activator writes
  the read-only `/etc`, and its infra units mount a tmpfs over
  `/run/wrappers` and rewrite `/etc/passwd`). `fortress-apply` builds the
  rendered unit tree (`#systemConfigs.fortress.unitsDir`) from the magic
  folder at RUN TIME, mirrors it into `/run/systemd/system`, and starts
  `fortress.target` (which wants exactly the enabled fortress services —
  never system-manager's infra). Net: fortress updates never touch
  `nixos-rebuild`; the closure the applier installs is not in the OS
  closure. **Proof** — `scripts/smtest-e2e.sh` (NixOS owns the machine; a
  boot trampoline runs `fortress-apply` against a magic folder) passes all
  three: dex serves OIDC discovery on :5556; the applied dex unit is NOT in
  `nix-store -qR /run/current-system`; editing `config.nix` (dex port →
  5557) + `fortress-apply` moves dex with no nixos-rebuild. **L1**
  `systemManagerWiring` pins the target wiring + userborn-disabled. Eval/
  build gotchas documented in `flake.nix`: overlays must flow through
  `makeSystemConfig { overlays }` (NOT `nixpkgs.overlays` — `types.anything`
  merges functions pointwise) and `lib.optionalAttrs` recurses (use `mkIf`).
  userborn is disabled (host OS owns users; keeps the Rust build out of the
  applier closure). host-shim stubs graduate to real imports per service.
- **LAN DNS on the applier + DynamicUser (2026-10-05)** —
  `fortress-dns` (`nix/nixos-modules/network.nix`) replaces nixpkgs'
  dnsmasq module, which is unusable on the ADR-035 applier path (it
  writes `/etc`, declares `users.users.dnsmasq`, and registers on dbus).
  The fortress-owned unit takes its config from a store path, so one
  definition serves `nixosModules.default` and `systemConfigs.*`; the
  `services.dnsmasq` stub is gone from `host-shim.nix`. **Identity
  policy** — the applier cannot create OS users (the host owns passwd), so
  exactly two identities are portable: `DynamicUser` for stateless
  services, root when a stable UID is required. fortress-dns is stateless
  and runs in the dynamic range (uid 61865). Two startup bugs found and
  tripped: dnsmasq insists on a pidfile and dies (exit 3) without a
  writable one (`RuntimeDirectory`), and a bind losing the race to DHCP
  exhausted systemd's start limit in ~1s (`RestartSec = 5`). **Proof** —
  `scripts/smtest-e2e.sh` [3/4]: `dex.example.com` and `example.com`
  resolve to 10.0.2.15 from the applied closure, the Firefox DoH canary
  NXDOMAINs, and the running uid is not 0. **L1** `systemManagerWiring`
  pins the unit + `DynamicUser` + `RuntimeDirectory` + `RestartSec`.
  OS remnants that stay NixOS-side: `firewall :53`, and the box must not
  resolve through its own fortress-dns (`fortress-apply` re-checks the
  live `/etc/resolv.conf`, since the eval-time assertion is vacuous on
  the applier path).
- **Service identities are ADR-036 root (2026-10-05)** — jellyfin,
  cryptpad, qbittorrent, radarr, sonarr now run as root; the
  hand-rolled `users.users.{jellyfin,fortress-cryptpad}` and the shared
  `jellyfin` media *group* (qbittorrent/radarr/sonarr ran `group =
  jellyfin` into dirs chowned `jellyfin:jellyfin 770`) are gone, along
  with the `chown <svc>:jellyfin` / `install -g jellyfin` calls that
  referenced them. nixpkgs guards each account with
  `mkIf (cfg.user == "<name>")`, so `user = "root"` makes the account
  vanish without producing `users.users.root` (verified by eval).
  **This is the fix for the applier path** — those accounts were
  inert there and the units would have died. Two latent bugs surfaced
  and are now tripwired: nixpkgs' jellyfin module ships
  `PrivateUsers=true` (breaks root outright, jellyfin#7897) and
  `NoNewPrivileges=true` (silently kills hardware acceleration,
  jellyfin#7887) — both forced off in `jellyfin.nix`, both asserted in
  `vmtest-wiring`, which also now asserts root on jellyfin/qbittorrent.
  Proof: `scripts/vmtest-e2e.sh` E2E PASS (`cryptpad -> /data/cryptpad/data
  writable as root`, `jellyfin -> /data/jellyfin/metadata writable as
  root`, `media-apply pipeline applied`) + `scripts/status.sh` 4/4.
  Consequence on the NixOS path: amon-sul's jellyfin becomes root on
  its next rebuild (HWA is unaffected — `PrivateUsers` was already
  mapping `render`/`video` to nobody, so `extraGroups` was dead).

- **Forgejo runs under `DynamicUser` (2026-10-06)** — resolved, and
  it is now the reference shape for ADR-036: `DynamicUser` +
  `StateDirectory`, state at `/var/lib/forgejo` so systemd re-owns it
  on every start (the only UID-reuse-safe location per systemd.exec(5)).
  Forgejo hard-refuses root (`log.Fatal`, and build jobs/git hooks run
  untrusted repo content as the run user), so root was never an option
  here. Two traps handled: nixpkgs' tmpfiles rules name `cfg.user`, so
  `user`/`group` point at `root` to keep those rules valid on a host
  the applier cannot add accounts to while the `mkIf (cfg.user ==
  "forgejo")` guard suppresses the account; and `RUN_USER` lives at
  `settings.DEFAULT.RUN_USER` (not `settings.RUN_USER`) and must name
  the dynamic user or Forgejo refuses to start. Cost accepted
  deliberately: repos leave the btrfs pool, so no quota or snapshots
  on them — revisit if restic makes the pool the backup boundary.
  Proof: `scripts/vmtest-e2e.sh` E2E PASS (`forgejo under /git (strip
  row) 200`) + `scripts/status.sh` 4/4. `vmtest-wiring` asserts
  `DynamicUser`, `StateDirectory` and `RUN_USER` so this cannot
  silently regress.

- **`public = true` without `enable = true` now fails loudly
  (2026-10-06)** — was a silent no-op. Root cause was structural, not a
  typo: the whole module body in `services/_contract.nix` sat inside
  `lib.mkIf cfg.enable`, **including its own assertions**, so when
  `enable = false` nothing was evaluated at all. The assertion that
  would have caught it was gated on the very flag it was meant to
  check. Now ungated (`lib.mkMerge` with the check outside `mkIf`).
  Proven live on amon-sul 2026-10-06: cryptpad + forgejo were
  `public = true` / `enable = false`, and both units are `not-found`
  on the box (never deployed). `scripts/status.sh` 4/4.

- **amon-sul deployment blockers (2026-10-06, measured not assumed)**
  — SSH'd to the box and evaluated its config against current cococoir.
  Three things stand between it and a clean deploy:
  1. `fortress.secrets.sopsFile` is unset → `adminPasswordEnvFile is
     not set` assertion. One line + an age key; `sops-wire.nix`
     auto-wires the rest. (The `amon-sul.nix:16` comment claiming "no
     sops wiring is needed" is half-true — service secrets are
     first-boot generated, the **dashboard admin hash is not**.)
  2. cryptpad + forgejo: `public` without `enable` (see above).
  3. `qbittorrent` is enabled but exits 0 within ~1s and never returns
     (last touched Sep 22) — pre-existing, unrelated to this work.
  Also: limonene's `nix flake check` fails on `ionos-vps`
  ("fileSystems … does not specify your root file system"), unrelated,
  so a bare flake check there is not a usable gate.
  **Not** blockers: no forgejo data migration is needed (`/var/lib/forgejo`
  is already where the new `stateDir` points; `/media/forgejo` was never
  created), and amon-sul evaluates to a toplevel drv once #1 is set.


- **The magic folder now builds an applier-consumable config
  (2026-10-06)** — this was the real amon-sul blocker, not sops.
  `scripts/fortress-bootstrap.sh` generated a **`nixosConfigurations`
  flake** (`fortress.nixosModules.default`), but `fortress-apply`
  consumes `#systemConfigs.fortress.unitsDir` — so a bootstrap-generated
  folder could never be applied, and amon-sul would have been pointed at
  `nixos-rebuild` forever. It now emits
  `systemConfigs.fortress = cococoir.lib.mkFortressSystemConfig
  (import ./config.nix)`, plus `fortress.storage.backend = "plain-dirs"`
  (the host owns btrfs; fortress only writes under `dataRoot`) and no
  `networking.hostName` (OS-owned, and not stubbed on this path).
  **Proof**: bootstrap → `nix build .#systemConfigs.fortress.unitsDir`
  yields a unit tree in which `fortress.target` has
  `Wants=caddy.service dex.service` and **every** `.service` has an
  `ExecStart`. Plus `scripts/status.sh` 4/4 and `vmtest-e2e.sh` E2E PASS.

  Also landed with it:
  - **Admin password is a passphrase now** — `xkcdpass -n 5 -d -`
    (correct-horse-battery-staple, ~64 bits, speakable) replaces
    `openssl rand -base64`. Shown **once** at first run, recoverable via
    `sops -d`. Jellyfin's admin password likewise.
  - **Bootstrap is self-sufficient** — it re-execs under `nix shell` for
    whatever it lacks. amon-sul has **none** of age-keygen/sops/openssl/
    xkcdpass; nix is the one thing it does have, so that is the portable
    substrate rather than a per-distro support matrix.
  - **`fortress.target` was not pulling in Caddy.** It listed only catalog
    services, and the applier deliberately never starts
    `system-manager.target` (where caddy's unit was hanging) — so a
    public service would have been unreachable. Fixed + L1 tripwired.
  - **Stubbed services now fail loudly.** A stub is worse than a no-op:
    the fortress wrapper still emits its `systemd.services.<name>` block
    but the nixpkgs module supplying `ExecStart` is absent, so systemd
    gets a unit it cannot start. `host-shim.nix` asserts against enabling
    one.

- **Why the rest stay root (2026-10-06)** — checked, not assumed.
  Jellyfin/qbittorrent/radarr/sonarr share the media tree and it is
  genuinely multi-writer: qbittorrent writes `downloads/`, radarr and
  sonarr hardlink into `library/`, jellyfin reads it. Per-unit dynamic
  UIDs cannot express shared mutable ownership, and a shared static
  group needs an OS account the applier cannot create — so this is
  exactly the case where `DynamicUser` "introduces extra bugs".
  Jellyfin is separately blocked: `DynamicUser` implies
  `NoNewPrivileges=true` and systemd.exec(5) says it *cannot be
  disabled*, which breaks jellyfin's `restart.sh` (jellyfin#7887).
  Cryptpad is the one genuine open candidate for `DynamicUser` —
  single-writer, own data dir — at the cost of moving its documents
  off the pool.
- **Install script — ADR-035 scaffold (2026-10-02)** —
  `scripts/install.sh` (served at `/install.sh`, `include_str!`'d in
  site + controlplane + the package filter): OS detection
  (macOS/Linux/NixOS) + reports the ADR-035 install method (Linux
  native / macOS-Linux VM). The Docker container-tier installer was
  removed with the tier (ADR-035 supersedes ADR-030). Honest stub —
  it installs nothing yet; the automated provisioners for the two
  methods are the install-flows work.

- **onbox-config-secrets install flow — magic-folder bootstrap
  (2026-10-02, flat shape amended)** — `scripts/fortress-bootstrap.sh`,
  the shared first-run generator behind every install target (NixOS
  oneshot / install script / the Mac-Windows VM). Generates the magic
  folder idempotently: device age key at `$ROOT/system_age_keys.txt`
  (outside the repo, 0600) + a git repo at `$ROOT/config/` holding the
  flat `config.nix` (editor-managed app config: services + remote-access
  + users) + `flake.nix` + `flake.lock` (best-effort) +
  `secrets/secrets.enc.yaml` (sops-sealed). **Proof** (temp-dir run):
  flat structure correct (`config.nix`/`flake.nix`/`secrets/`/key);
  device key is NOT git-tracked; sealed file is ciphertext-only (no
  plaintext leak); round-trip `sops -d` with the device key yields a
  valid `$2b$10$` bcrypt admin hash; re-run is idempotent (key unchanged,
  no new commit); config + ciphertext share one git history (the
  atomic-rollback shape). `flake.lock` is best-effort offline (auto-added
  on first rebuild). Shape decision (2026-10-02): **flat `config.nix`**
  (not a services/remote-access split) — matches the built single-file
  editor; one rollback unit. Not yet wired into install targets / applied
  by an applier (onbox proposal T2/T4/T5).
- **sops-wire admin-template fix (2026-10-02)** — the admin env
  template rendered `config.sops.secrets.<n>.path` (a `/run/secrets/…`
  file PATH) instead of the secret VALUE; the client reads a path as
  the bcrypt hash and every dashboard login breaks silently. Fixed to
  `config.sops.placeholder.<n>` (the token sops swaps for the decrypted
  value at activation). **Proof**: `sopsAdminTemplate` (L1) asserts the
  placeholder construct is present and the path-construct is gone;
  `nix flake check` green. (Device-key path now
  `/etc/fortress/system_age_keys.txt` per the flat-shape decision.)
- **config-ui arc — T1 round-trip done; editor found already built
  (2026-10-02)** — the fortress-client dashboard **already** reads,
  renders, and atomically saves a single Nix config (service toggles +
  remote-access fields + users) via `nix_config_parser` — the config-ui
  draft wrongly assumed it needed building. Amended: the arc is really
  the **apply / revert / applier** half (git-commit edits, run the
  rebuild, surface the result, revert via the UI), which does not exist
  yet. **T1 proof**: `ui_edits_round_trip_on_split_concern_modules`
  (L0) — service toggle + remote-access field round-trip losslessly;
  28/28 parser tests green. Remaining: T2 (point editor at flat
  `config.nix`), T3 (apply), T4 (revert), T5 (applier spike — the
  load-bearing piece). See `.specify/specs/config-ui/proposal.md`.

## Works
- **Path-based routing: one origin per plane + failover matrix
  (2026-09-26, ADR-034)** — every catalog service answers at
  `/<name>` on every plane origin (`https://<baseDomain>`,
  `http://<lanAddress>`, `http://<label>.i2p`), whatever its routing:
  path-routed rows (dex `/dex`, forgejo `/git`, jellyfin, radarr,
  sonarr) proxy there; subdomain-canonical rows (seerr, cryptpad) 307
  there — and every hostname shape 307s back, so `/<name>` is a
  uniform entry point and flipping a service's routing swaps
  redirects, not customer URLs. **The headline UX is live: with no
  remote access, `http://<lanAddress>/jellyfin` serves Jellyfin and
  `http://<lanAddress>/seerr` 307s to its DNS-free LAN port-site**
  (Caddy on `http://<lan>:5055`, public-gated, loopback app;
  cryptpad is `originLocked` and fails over to its own origin — a
  second origin breaks its safe/unsafe model). All fortress Caddy
  rendering lives in one new `nix/nixos-modules/planes.nix` (service
  modules never write vhosts — no module-merge seams); Set-Cookie is
  rewritten to `Path=/<name>` on every plane proxy (A5, fingerprint
  asserted live on forgejo's cookies); the loopback dex issuer's
  Location is rewritten once per plane and clearnet-canonical
  callbacks are swapped onto the browser's plane (LAN + I2P). Per-app
  base URLs: jellyfin `network.xml` `<BaseUrl>` (ExecStartPre),
  *arrs' `config.xml` `<UrlBase>`, forgejo `ROOT_URL`, and every
  internal consumer (jellarr `base_url` + readiness probe,
  media-apply's seerr↔arr↔jellyfin handshakes) carries the path.
  **Audit correction:** forgejo's `ROOT_URL` is URL-generation only —
  it serves at its root, so its rows strip `/git` (`stripPath`;
  T0's "GREEN" assumed sub-path serving). **SSO completes on the
  plain-HTTP LAN origin** (A9: no Secure cookie is load-bearing in
  the flow — finding recorded in the proposal). Contract additions
  are internal/derived (`routing`/`path`/`stripPath`/`originLocked`);
  ADR-034 + constitution p.1 amended in the same change. Also fixed
  first: cryptpad and the config dashboard both claimed
  `127.0.0.1:3000` — dashboard moved to `:3210` with a collision
  assertion (tripwired). Proof: `scripts/vmtest-e2e.sh` PASS (Last
  e2e line) incl. a new "Path-routing matrix" block (stub307s,
  failover307s both directions, LAN bare-IP jellyfin 200, seerr
  port-site 200, forgejo strip row 200, A5 cookie fingerprint) and
  full SSO flows on both the I2P and LAN planes + `vmtest-wiring`
  matrix tripwires + `contract-conformance`/`doc-refs` PASS.
- **Site machines dashboard + real edge boot (in progress, 2026-09-26)** —
  the topcoat arc's T4+T6+T7 merged into one proposal
  (`.specify/specs/site-machines-dashboard/proposal.md`; T7 folded in by
  user call to avoid a two-edge-binary window). Landed and L0-verified:
  `ControlPlane::root_domain()` (T1); the site now boots the process
  globals — `install_crypto_provider` + `init_globals` → the real
  forwarder/WG/DNS and the store-held edge identity, replacing the
  hardwired `MockWgClient`/`MockDnsApiClient`/`DUMMY_EDGE_WG_PRIV`, with a
  value-less `--dummy` that compiles only into debug builds (T2 —
  `crates/site/src/main.rs`, which also gains the reconnect loop and
  graceful shutdown the edge had); the account dashboard moved to
  `fortress-web-ui` (`MachinesPage` + `machines_html`, primitive rows) so
  the poem controlplane and the topcoat site render **one markup source**
  (T3 — the `Landing` precedent). `SiteBackend` now holds
  `&'static ControlPlane` + `&'static dyn Mailer` (the process globals).
  Proof: `cargo test --workspace` **233/233** (2026-09-26) incl. the new
  `machines_dashboard_renders_rows_statuses_and_waiting_forms`,
  `machines_dashboard_handles_the_empty_account_and_the_error`,
  `root_domain_is_readable_without_touching_secrets`, and the site's
  `parse_args` tests; `cargo check -p fortress-site --release` clean;
  `nix build .#checks.x86_64-linux.redis-tier-compiles` PASS.
  **Not yet done: T5 (the L2 nixosTest), T6 (operator/health API port),
  T7/T8 (nix cutover), T9 (docs). The site's real boot path is L0-only
  until T5 — do not claim it boots.**
- **Site `/machines` dashboard + owner ops (2026-09-26)** — T4 landed.
  `crates/site/src/pages/machines.rs` serves `GET /machines` plus the
  four owner ops at the exact paths the shared `MachinesPage` emits
  (`/auth/invite`, `/auth/invite/{code}/{approve,deny,revoke}`), session-
  gated and PRG (`?invited=`/`?error=<ident>`, never a message). The
  domain mapping is shared via `controlplane::web::machines_props` (now
  pub) so the poem and topcoat dashboards cannot drift.
  **Sign-out root fix** (user call, not a parity hack): `sign_out_form()`
  in web-ui emits a POST form, both surfaces serve `POST /auth/logout`,
  and the dead `POST /logout` plus the poem's mutating `GET /auth/logout`
  are gone — the landing's "Sign out" link used to 404 and silently
  leave the customer signed in.
  Tripwires added in the same change:
  `sign_out_is_a_post_form_at_the_contract_path`,
  `dormant_invite_offers_revoke_but_never_an_approve_form`,
  `machines_props_maps_every_invite_status_one_to_one`,
  `dashboard_contract_paths_resolve_and_gate_on_the_session`, and 3 in
  `site/src/account.rs`. Proof: `cargo test --workspace` **240/240**, 0
  warnings (2026-09-26).
- **BLOCKED (2026-09-26): concurrent editor on `pairing.rs`.** A second
  writer landed the `Dormant` invite lifecycle
  (`dormant → waiting → approved/denied`; approve/deny before `begin` →
  `InviteError::NotBegun`) and a code-scheme refactor (10-char Crockford
  base32 → 4 hyphen-joined words from `src/words.txt`, e.g.
  `polluted-move-cheetah-apple`; `is_valid_invite_code` →
  `canonical_invite_code`), **during this session** — proven: the
  `Dormant` variant appeared after a green run on a 3-variant match, and
  `pairing.rs`'s mtime (20:01) is newer than every file this session
  edited (19:46–19:49). Both changes are carried through the surfaces
  that render them (dashboard gates approve/deny to `waiting`; `Dormant`
  shows Revoke + "waiting for the machine to connect"; `NotBegun` → 409
  on the `/api` wire). The tree is RED only because the refactor is
  half-landed: production is converted but these leftover test
  references to deleted symbols are not —
  `pairing.rs:1038,1041,1059,1060` (`CODE_LEN`, `CROCKFORD`) and
  `pairing.rs:1039,1045,1046,1059` (`is_valid_invite_code`), 12 errors.
  Deliberately NOT patched — that is in-flight work. Hand back to its
  author; the port is mechanical (`canonical_invite_code(code).is_some()`
  and a word-count assertion). Everything above is green against the
  tree as it stood before that rewrite landed.
- **LAN-IP dashboard homepage (2026-09-25)** — typing the box's LAN
  address now serves the embedded config dashboard: no DNS, no port to
  remember. `network.nix` adds one Caddy vhost, `http://<lanAddress>`,
  gated on `fortress.network.lanAddress` — HTTP-only (no auto-HTTPS
  redirect) and keyed to the concrete LAN address, **never a hostless
  `:80` catch-all**, which would shadow the ACME HTTP-01 challenge
  responses for service domains and silently break cert issuance. The
  dashboard bind became configurable (`services.fortress-client.dashboardAddr`,
  default `127.0.0.1:3000`; new `-dashboard-addr` client flag) and now
  defaults to loopback — it was hardcoded `0.0.0.0:3000`, so the config
  editor listened on every interface including the tunnel IP; Caddy is
  the LAN ingress and the forwarder owns the tunnel IP, so it must not.
  Proof: `vmtest-wiring` PASS with a new LAN-dashboard assertion set
  (vhost exists, binds `10.0.2.15`, proxies `127.0.0.1:3000`, carries no
  `tls` line); `contract-conformance` / `doc-refs`
  PASS; `cargo test -p fortress-client` 72/72; the generated Caddyfile
  builds (`caddy fmt` accepts it) as `http://10.0.2.15 { bind 127.0.0.1
  ::1 10.0.2.15; reverse_proxy 127.0.0.1:3000 }`. **Not boot-proven**:
  no NixOS config enables `services.fortress-client` yet (T10), so the
  dashboard backend is absent in `vmtest` and the L2 curl
  (`http://10.0.2.15/` returns the dashboard) lands with T10/T11. **LAN
  leg only**: the vhost matches `Host: <lanAddress>`; remote dashboard
  access needs its own cert-bearing domain vhost (TLS SNI), out of scope
  here.
- **comma (with its database) on every fortress box; example123 demo box
  deleted (2026-09-23)** — the raw `comma` binary is a dead end on its own:
  it is a wrapper around `nix shell -c` + `nix-index`, so `, foo` cannot
  resolve the name→attrpath without the command-index database. Fortress now
  wires `comma-with-db` (nix-index-database's SMALL /bin-only database,
  ~1.7 MB via `NIX_INDEX_DATABASE`; the 92 MB full DB buys nothing for comma)
  through the nix-index-database overlay on `withCrane` (the mkPkgs factory),
  so every machine — customer box, vmtest, edge — gets a comma
  that actually works, plus `nix.settings.experimental-features` (mkDefault,
  comma needs nix-command + flakes), zero customer-facing config. The edge
  box takes `comma-with-db` via specialArgs (`commaWithDbPkg`, since
  system-manager doesn't use the fortress overlay) +
  `experimental-features = nix-command flakes` in provision-edge.sh's
  nix.conf append. The tofu-rendered example123 demo customer box is
  **deleted** — the repo is a library/template for other people's home
  servers, not a shipped demo: `templates/example123.nix.tftpl` +
  `remote-infra/nix/example123.nix` removed, along with its tofu scaffolding
  (`customer` var, `customer_aaaa` rrset, `customer_ipv6`/`customer_wg_ip`
  locals + output, `render.tf` resource). `demo-verify.sh` now requires an
  explicit `<baseDomain>` (customers are provisioned at runtime by the control
  plane). Proof: `nix flake check` all-pass (doc-refs/contract-conformance/
  vmtest-wiring/edge-store-wiring) + `tofu validate` + `status.sh` 3/3 PASS +
  `nix eval` of vmtest systemPackages shows `comma-with-db-2.4.2` and the edge
  systemConfig resolves `comma-with-db` (2026-09-23).
- **T5: `/api/*` is the real controlplane domain (2026-09-22)** — the
  wire-shape stubs in `crates/site/src/api.rs` are gone. Every handler
  delegates to `ControlPlane` and maps the outcome into the byte-for-byte
  wire shape `pairing.rs` reads: `invite_begin`/`invite_poll` →
  `cp.invite_begin/poll`, `wireguard_pubkey` → `cp.edge_public_key()`,
  `device_register` → `cp.device_register` (204). The domain's own
  `PollOutcome` is deliberately NOT returned directly — its `device_token`
  serde-serializes snake and it leaks the full `Machine` record — so
  `map_poll` is the single wire gate (only `machine.wg_ip` + camel
  `deviceToken` cross). Backend reaches handlers as axum `State`. Proof:
  `cargo test --workspace` 223/223 (2026-09-22) incl. a **store-backed
  full enrollment through the composed router** (`enrollment_e2e_tests`,
  REDIS_URL-gated, mirrors the exact `pairing.rs` calls: begin → approve →
  poll delivers tunnel+token once → rotate → wrong-token 401), plus
  `map_poll_produces_the_pairing_wire_shape` (no machine fields leak) and
  `composed_router_renders_a_page_that_reads_app_context`. Live boot of
  the site binary confirmed: `/api/wireguard/pubkey` returns the derived
  edge identity, begin/poll/register answer domain-shaped 400/404, and
  unmatched paths fall through to topcoat 404. **Two boot bugs found and
  killed by live boot, both with tripwires**: (1) `app_context` in the
  pages asked for `&SiteBackend` (i.e. `T = SiteBackend`) while the router
  registers `&'static SiteBackend` — topcoat keys context by `TypeId`, so
  pages panicked at request time; fixed with a `site_backend(cx)` seam in
  `lib.rs` + the composed-router tripwire. (2) `main.rs` passed `--wg-pubkey`
  (empty) into `with_deps`'s `wg_private_key` slot, so `edge_public_key()`
  failed → `/api/wireguard/pubkey` 500'd; the flag is deleted and the
  binary boots with `DUMMY_EDGE_WG_PRIV` (dev/dummy identity; T6 swaps in
  the store-held production key). **Devenv rust toolchain (2026-09-22)** —
  `devenv.yaml`/`devenv.nix` now pull `rust-overlay` pinned to the flake's
  exact rev and expose `rust-bin.stable."1.98.1"` (wasm32 target,
  rust-src/rust-analyzer/clippy/rustfmt), so a cold `devenv shell` has a
  working toolchain for the edition-2024 site crate without the flake's
  1.97.1 pin.
- **Presentation pivot: topcoat + axum, no wasm (2026-09-22, ADR-033
  revised)** — the dioxus fullstack half of ADR-033 is abandoned. The
  wasm/hydration tier was a permanent tax (two-leg crane build,
  wasm-bindgen 0.2.127 shim, multi-session hydration proofs) that the
  site's shape does not earn: it is forms + one dashboard + static
  content. The pivot also removes a real vulnerability class — the
  dioxus port's `<form onsubmit=...>` with no `method` defaulted to
  GET, so any missing/broken handler put passwords in the query string
  (browser history, server logs, Referer). New composition, proven by
  the T1 spike: **axum owns `/api/*`** (utoipa, the `pairing.rs`
  machine contract, `/api/openapi.json`) and **topcoat owns every human
  HTML surface**, mounted as axum's `fallback_service` via
  `TowerService`. Merged at the root with full `/api/...` paths —
  axum's `nest` strips the prefix and would 404 every route (T1 seam
  #1). Landed: root layout + `landing_html()` raw at `/` (framework-
  independent, shared byte-for-byte with the edge landing) +
  `/docs{,/{slug}}` + `/install.sh`; auth surfaces as topcoat `#[page]`s
  with **Post/Redirect/Get** (`/register` `/login` `/logout` `/forgot`
  `/reset` `/verify` `/resend` `/a/{code}` `/account/delete`), failures
  redirecting on a short `error=<code>` token — never a message, never a
  credential. Deliberately NOT adopted from topcoat: `mail`, `session`,
  `asset`/`font`/`icon`, `ui` (controlplane owns `Mailer` + the session
  store; web-ui's ZINE_CSS/LOUD_CSS is the zero-external-origin design
  system). Proof: `cargo test --workspace` 219/219 (2026-09-22) incl.
  `credential_forms_declare_post` + `no_form_literal_omits_post` (the
  GET-credential leak cannot return), `pairing_wire_shapes_hold` (the
  mixed snake-in/camel-out contract pinned),
  `pairing_wire_paths_land_on_the_api_tree` (T1 seam #1 against the real
  `pairing.rs` wire paths), `openapi_spec_carries_the_pairing_contract`,
  `pages_have_no_external_asset_origins`.
  **Unresolved migration cost:** topcoat >= 0.7 requires **rustc 1.98**
  and its `#[page]`/`#[component]` macros require **edition 2024** RPIT
  capture semantics. `crates/site` is now edition 2024; the flake's
  `nix/packages/site/default.nix` still pins `rust-bin.stable."1.97.1"`
  and will not build the site crate until bumped to 1.98.1. Local dev
  used a 1.98.1 toolchain built from the flake's own pinned
  `rust-overlay`. Not yet cut over: `main.rs`/`systemConfigs.edge` still
  point at the dioxus/wasm bundle (T7), the `/api` handlers are wire-
  shape stubs pending the real controlplane domain (T5), and
  `crates/client`'s `:3000` config dashboard stays poem (out of scope).
- **Forgejo git forge + Dex OIDC (2026-09-21)** — `services/forgejo.nix`
  on the 4-option contract factory (port 3001, `/api/healthz`,
  storageNeeded → auto-declared `forgejo-data` subvolume). SQLite under
  the dataRoot subvolume, loopback HTTP bind (Caddy is the ingress),
  ROOT_URL = the clearnet domain (Forgejo builds its OIDC callback from
  it), SSH disabled (git-over-HTTPS v1), DISABLE_REGISTRATION (users
  come in via Dex). `integrations/forgejo-oidc.nix` auto-wires when
  forgejo + dex are both enabled: secret oneshot → dex staticClient
  (clearnet + i2p `/user/oauth2/dex/callback`) →
  `fortress-forgejo-oidc-bootstrap` oneshot runs
  `forgejo admin auth add-oauth` (idempotent, then restarts forgejo —
  auth sources are DB-backed and cached in-process). One customer
  toggle: `fortress.services.forgejo.enable`. Proof:
  `contract-conformance` + `vmtest-wiring` (forgejo assertions) +
  `status.sh` 3/3 PASS (2026-09-21); rendered-config spot checks (dex client URIs clearnet+i2p,
  bootstrap after forgejo+dex, ROOT_URL/HTTP_ADDR/sqlite3). NOT yet
  boot-proven — e2e blocked by the jellarr pnpm hash landmine below.
- **Landing parity: one component, pixel-identical (2026-09-19)** —
  the site's landing was a bare hand-rolled page (2.4KB) that looked
  nothing like the deployed zine site; the user flagged it. Fix per
  DRY: `Landing`/`LandingProps`/`shield_icon` moved from
  controlplane/web.rs into `crates/web-ui` (with `landing_body` +
  `landing_html()`), controlplane imports the component (84 tests
  green, unchanged), and the dioxus site's `Home` injects
  `landing_html()` raw (static marketing content — hydration is a
  no-op). The committed `crates/site/public/index.html` is the zine
  document shell regenerated by
  `cargo run -p fortress-web-ui --example write_index` + the wasm
  script line, asserted byte-exact by the site's
  `public_index_carries_the_zine_shell` tripwire. Proof: headless
  firefox screenshots of :8081 (controlplane) and :8082 (site bundle)
  are **byte-identical** (same md5
  ebb25918a3c8c2e95d3024c5a0c7a821, /tmp/opencode/{old,new}-site.png);
  rendered text 4582 vs 4581 chars (one code-block brace); site tests
  8/8; wasm tier `cargo check` clean.
- **T2a: dioxus site serves /register + /login with embedded
  ControlPlane (2026-09-20)** — the migration's first app surface on
  the new stack. `crates/site` gains a server-gated
  `fortress-controlplane` dep; the site server main boots a
  forwarder-free `ControlPlane` (mock WG/DNS, dummy subnets; the
  account methods never touch the forwarder — it stays the edge's
  job) + a mailer, injected into every request's axum extensions. The
  dioxus `#[server]` fns `signup`/`verify`/`login`/`logout`/
  `current_session` in `crates/site/src/account.rs` are the poem
  `/auth/*` handlers' replacement — fullstack ergonomics, not form
  round-trips: components hold `use_signal` state, call typed server
  fns, re-render from typed outcomes; the session cookie is set on
  the response via `FullstackContext::add_response_header`. The
  landing's logged-in nav/CTA wired through `current_session` +
  `use_server_future`. Shared cookie + error helpers are now public
  controlplane exports. Proof: `cargo test -p fortress-site` = 9/9
  incl. the redis-gated `signup_verify_login_logout_fullstack_round_trip`
  (REDIS_URL=redis://127.0.0.1:6379, 2026-09-20) driving the real
  surface end-to-end (HttpOnly cookie asserted, signed-in SSR landing,
  logout clear); controlplane 84/84; wasm tier clean.
- **axum + dioxus fullstack site (2026-09-19, ADR-033 in
  progress)** — branch `axum-dioxus-migration` (now == main at
  2de6cd2): the site crate `crates/site` is dioxus 0.7 fullstack on
  axum 0.8. Plain axum routes (hard, they win) serve `/install.sh`
  (embedded repo script) and the pulldown-cmark markdown wiki
  `/docs{,/{slug}}`; the dioxus SSR application is the router
  fallback (currently the `/` landing with the curl card; app pages
  move here next). **Site SSR landed; hydration WAS NOT proven**:
  the router was claimed to "gate `serve_static_assets()` on the dir
  existing" and `/wasm/fortress-site_bg.wasm = 200` was claimed in a
  smoke — but `serve_static_assets()` was never wired into the
  router, so the bundle shipped `/wasm/*` and 404'd it (silent-failure
  seam, real browser showed `Loading module … blocked because of a
  disallowed MIME type ("")` on the login screen). **Fixed 2026-09-21**:
  the router now calls `serve_static_assets()` (safe — `ensure_public_shell()`
  guarantees `exe_dir/public` exists, so cargo tests stay SSR-only) and
  `static_assets_are_served_not_ssr_fallback` is a tripwire; verified
  against the debug binary with a wasm client built into
  `target/debug/public/wasm` (`/wasm/fortress-site.js` =
  text/javascript, `/wasm/fortress-site_bg.wasm` = application/wasm).
  Dev-loop caveat: `cargo run` does NOT build the wasm client — the
  dev `site` process needs a wasm build step (bundle builds it via the
  crane wasm leg + wasm-bindgen; a local `dx build --platform web` or a
  mirrored `cargo build --target wasm32-unknown-unknown` + wasm-bindgen
  into `target/debug/public/wasm` does the same). The nix-side bundle
  `.#siteBundle` is live: server leg = plain crane (deps cache shared
  with the fortress package), client leg = crane with the
  wasm-capable toolchain (`--no-default-features --features web
  --target wasm32-unknown-unknown`), glue = explicit `wasm-bindgen
  --target web` (0.2.127 — nixpkgs maxes at 0.2.105 and the lock
  can't downgrade below it: js-sys 0.3.104 via chrono needs newer;
  built via `buildWasmBindgenCli`) + the authored index.html.
  **dx is OUT of the nix pipeline** — dx drives cargo with
  dx-internal profiles, so crane's buildDepsOnly caching never
  applied and every nix build recompiled ~750 crates × 2 legs
  (~20 min). With the crane split a site-only change rebuilds the
  bundle in **7.6 s** (2026-09-19, vermissian, both legs + glue).
  Live smoke of the nix bundle: `<title>Fortress</title>`,
  `initial_dioxus_hydration_data` + module script present,
  `/wasm/fortress-site_bg.wasm` = 200 application/wasm,
  `/install.sh` + `/docs/nixos` = 200, zero external origins
  (custom `crates/site/public/index.html` — dx's default template
  imports Google Fonts; banned). `main.rs` is tier-gated (server
  axum boot / web `dioxus::launch`); mutual exclusion is a
  compile_error. **NOT yet proven: a real browser hydrating**
  (chromium/firefox headless hang in this env — needs a
  wasm-bindgen-test or browser harness). Dev loop = local
  `dx build --platform web` / `dx serve` (nixpkgs#dioxus-cli 0.7.9
  + wasm-bindgen 0.2.127 shimmed into
  XDG_DATA_HOME/dioxus/wasm-bindgen — the nixpkgs wrapper bundles
  0.2.118 on PATH, must be shadowed) against a warm local target/.
  **Nix proof landed**: `nix build .#systemConfigs.edge --no-link`
  PASS (2026-09-19, vermissian) — the md-inclusive crane filter
  compiles the whole workspace nix-side, closing the
  2026-09-18 memory-starved gap. The store-backed test tier that
  requires a real Redis is features-gated behind `redis-tests` on
  the controlplane (default off): `cargo test
  -p fortress-controlplane` = pure surfaces only,
  `--features redis-tests` = the deployment set (note: a local
  redis-server on vermissian means the default tier's
  account.rs/pairing.rs runtime-skip tests still RUN live here —
  they skip silently without Redis, not compile-gate).
  Proof: fortress-site tests 7/7 + wasm32 `cargo check` clean
  (dev toolchain carries the wasm32 std) + dx build exit 0 +
  hydration smoke above + `nix build .#systemConfigs.edge` exit 0.

- **secrets/ single-folder provisioning config (2026-09-18,
  secrets-folder-refactor)** — all operator-editable provisioning values
  live in `secrets/`: `facts.json` (every public tofu value, committed
  plaintext, replaces terraform.tfvars) and `secrets.enc.yaml` (sops
  store, committed as age ciphertext, moved from remote-infra/.secrets).
  provision-edge.sh applies tofu with `-var-file=../secrets/facts.json`;
  static tfvars deleted. Proof: `tofu validate -var-file=...` green +
  nix `builtins.fromJSON (readFile secrets/facts.json)` evaluates +
  status.sh `secrets-hygiene` tripwire (planted plaintext leak → exits
  1; clean tree → PASS) + store resolves post-move (`secretspec export`
  + `sops --decrypt`, both verified). Correction (2026-09-19): the
  original "clean tree → PASS" claim was FALSE — facts.json tripped
  the tripwire from the day it was committed; the tripwire now
  allowlists `secrets/facts.json` explicitly (public-by-design) so
  any other plaintext file under secrets/ still trips. Live tofu apply vs Hetzner not
  re-run — next operator re-provision exercises it for real.

- **Container tier — RETIRED (removed by ADR-035, supersedes ADR-030).**
  The Docker container tier (`nixosConfigurations/fortress-container.nix`,
  `scripts/container-e2e.sh`, the `container-wiring` L1) is deleted;
  install is now Linux-native + Mac/Windows VM. `storage/plain-dirs.nix`
  (the non-btrfs backend) survives for the VM tier. **Known gap:**
  `container-wiring` was the only check rendering `plain-dirs` tmpfiles
  (`/data/*`); that coverage is gone with it and returns when the VM tier
  (plain-dirs' next user) is built + tested. History: `git log`.

- **v0 L4 forwarder — Rust (ADR-024)**. 138 `cargo test`s across the
  workspace. CLI flags, config JSON schema, binary names, `/status`
  JSON contract unchanged. Proof: `forwarder-unit-tests` PASS.
- **Edge L2 e2e** (`.specify/specs/edge-l2-e2e/`) — Redis-backed edge
  systemd unit, `POST /signup`, signup → `/128` → WG → customer-box →
  HTTP. Proof: `nix build .#checks.x86_64-linux.edge-forward` PASS.
- **Rust workspace (ADR-026)** — `fortress-core` / `fortress-controlplane`
  / `fortress-client` crates; edge's secrets in
  `crates/controlplane/secretspec.toml`, operator provisioning secrets
  in the root `secretspec.toml`.
- **Control plane (demo slice)** — `POST /signup` (atomic Redis INCR
  allocates `/128`, WG keypair, live forwards, DNS), `GET /customers`,
  `DELETE /customers/:username`, `GET /pubkey`; bearer admin auth.
  **DNS-on-signup** (Hetzner client, reconcile loop every 2h); **edge
  runtime wiring** (live `wg set`); **edge process globals** (`'static`
  OnceCells, no AppState).
  Proof: `cargo test` + live Valkey round trip.
- **Edge-HA foundations (2026-09-07, DELETED 2026-09-14)** —
  floating-IP driver (`float.rs`), shared `wg0` identity, and the
  external-store lease (`lease.rs`, `ha.rs`) built for the hot-hot pair.
  The pair was **cut before ship** (ADR-029 pivot) and the machinery was
  then **deleted from the tree** (git history preserves it). Retained
  pieces that still run: the store-held `WG_PRIVATE_KEY` (stable identity
  across rebuilds) and the external `REDIS_URL` store (the control
  plane's persistence). Proof of what landed (not what ships): `cargo
  test --workspace` green + `nix flake check` green on vermissian
  2026-09-11 (incl. `edge-store-wiring` + the fixed L2 `edge-forward`).
- **Health server on poem + poem-openapi** — `/healthz` `/readyz`
  `/status` byte-exact + `/openapi.json` + `/docs`. Proof: L2
  `edge-forward` PASS.
- **7 service modules on the `_contract.nix` factory** (jellyfin,
  cryptpad, dex, radarr, sonarr, lidarr, prowlarr) + Dex OIDC
  integrations (jellyfin-oidc, cryptpad-oidc). Proof:
  `contract-conformance` + `vmtest-wiring` PASS.
- **btrfs storage** (ADR-023) — pool + per-service subvolumes with
  quota + owner. Proof: fresh boots 2026-07-31 + 2026-08-01.
- **CryptPad SSO end-to-end** on fresh boot (2026-08-01); optional
  drive password (`sso.cpPassword = true`).
- **Config editor + bare `dashboard.nix`** — the customer's editable
  surface; lossless `nix_config_parser` (round-trip law); Save is
  all-or-nothing (temp + rename). Password auth + sqlite sessions.
  Proof: `cargo test` + vmtest boot.
- **Nix config parser** (2026-08-13) — lossless round-trip on rnix +
  rowan; schema layer decouples known attrpaths.
- **Media automation stack (2026-09-15)** — one
  `fortress.services.media.enable` toggle brings up radarr + sonarr +
  qbittorrent + seerr, fully wired at boot: qbt categories → arr root
  folders/download clients/hardlink imports → seerr connected to
  Jellyfin + both arrs (jellarr applies libraries). lidarr/prowlarr
  removed. Proof: fresh-boot `vmtest-e2e.sh` PASS (41 checks incl.
  qbt categories, arr download clients, seerr wiring) 2026-09-15.
- **Local edge dev loop via `--dummy`** (2026-09-15) — the real edge
  binary runs on a dev box with no secrets/wg0/DNS: injected mock
  WG/DNS clients, console mailer, real forwarder + Redis store + HTTP
  wiring.   `--dummy` compiles ONLY into debug builds (`cfg!`
  `debug_assertions`) — a release edge rejects it (tripwire tests in
  both profiles). `nix run .#dashboard-dev` now boots a throwaway
  redis + the dummy edge at :8081 + the fortress-site crate at :8082
  (site process added to nix/dev/process-compose.nix). Proof:
  `cargo test -p fortress-controlplane` PASS; debug boot served `/`
  200 + `/api/healthz` ok; release `--dummy` errors; pc run 2026-09-18
  served site landing + `/docs/nixos` 200 and the edge API 200.

- **Accounts + machine enrollment, T4–T9 (2026-09-16, ADR-032).** The
  self-serve onboarding layer: account = email + internal UUID (no
  username; signup form + `/api/users/register` take email+password
  only); one account owns many machines at flat
  `<machine>.proletariat.tech`; enrollment = owner-generated 10-char
  Crockford invite URL (`{domain}/a/<code>`, 30d TTL, revocable) →
  machine dials `/api/invites/{code}/begin` → owner approves + names
  it on the `/machines` dashboard → one-time delivery of tunnel config
  + device token; `POST /api/device/register` rotates the pubkey on
  the same route token-only (closes ADR-025's deferred gap);
  `Customer`→`Machine` (owner field), Redis keys `fortress:machine:*`;
  `validate_machine_name` = ≥6 chars + reserved words (squat tripwire
  test); account deletion unwires everything, never wipes the box.
  Client side: `pairing.rs` enrolls via the invite URL (begin → poll →
  persist tunnel.json + 0600 device-token), boot prefers persisted
  state, forwards use the `{tunnel_ip}` placeholder. Amended
  proposal: wire shape renamed (`name`/`machine`), invite paths under
  `/api/invites/*`, inactivity-release REJECTED (names recycle on
  machine delete only). Proof: 79 controlplane + 71 client tests PASS
  (live Redis, `REDIS_URL=redis://127.0.0.1:6379`), incl.
  `api_invites_round_trip`, `machine_name_policy`,
  `account_record_has_no_username_field`, `account_delete_unwires_...`,
  `machines_dashboard_invite_approve_flow`; `edge-forward` L2 PASS
  (new wire shape) + `scripts/status.sh` 3/3. T10/T11 (single-VM
  onboarding e2e) pending.

## Fixed this session (2026-08-30)

- **Flaky forwarder tests (AddrInUse) — race against the host, not
  sibling tests.** `pick_free_*` probed a port via `bind(127.0.0.1:0)`,
  released it, then re-bound it later. The nix build sandbox shares the
  host's loopback, so on a busy box (amon-sul) the released port is
  handed to a live process before the test re-binds it — a lock
  serializing tests cannot fix that, and didn't. **Fix:** the forwarder
  records the *actual* bound address in `stats()` (`record_bound` now
  stores `local_addr()`), and tests give forwards a `:0` listen addr and
  read the kernel-assigned port back via `bound_port()`. Upstreams bind
  `:0` and keep the listener. No test releases-and-rebinds a port, so
  the race class is impossible by construction. Deleted `pick_free_*`,
  `testutil.rs`, and the lock. Net -36 lines. Proof:
  `nix build .#checks.x86_64-linux.forwarder-unit-tests` PASS; deployed
  on amon-sul.

## Fixed this session (2026-08-23)

- **Dead `storageNeeded` tripwire** (`_contract.nix`): the storage
  assertion read a non-existent option and could never fire. Now asserts
  the real factory arg `hasBucket` → `fortress.storage.enable`.
- **`RoutingTable` deleted** — it was write-only (production never read
  it; the forwarder is the source of truth). 160 lines + a global +
  rehydrate writes gone. Proof: `cargo test` green.
- **Signup failure compensation** — a failed WG/bind no longer burns the
  username + `/128` (the customer's private key is returned once, so a
  zombie record would lose it forever); `rollback_signup` unwires +
  drops the store entry.
- **Delete unwires before storing** — the store entry is removed last so
  a mid-delete failure can't orphan listeners rehydrate can't see;
  corrupt records are logged loudly, not skipped silently.
- **Piracy services require jellyfin** — radarr/sonarr/lidarr/prowlarr
  now assert `jellyfin.enable` (factory `requires`). Tripwire:
  `contract-conformance` checks the `requires` line. Proof: eval
  `radarr.enable` w/o jellyfin fails, with jellyfin passes.
- **`example123` out of the flake** — it's a tofu-rendered placeholder
  with no real disks/bootloader; it kept `nix flake check` permanently
  red. **`nix flake check` is now green.**

## Broken / landmines

- **Site crate will not build on the flake's pinned toolchain
  (2026-09-22).** topcoat 0.8.1 declares `rust-version = 1.98` and the
  site crate is edition 2024 (topcoat's `#[page]`/`#[component]` macros
  emit `impl View` capturing macro-injected lifetimes — edition 2021
  fails with E0700). `nix/packages/site/default.nix` pins
  `rust-bin.stable."1.97.1"` and must go to `"1.98.1"`; the same applies
  to whatever the dev shell/CI uses. Verified build+test only against a
  locally-built 1.98.1 from the flake's pinned `rust-overlay`.
- **e2e gate red on HEAD (pre-existing, 2026-09-21): jellarr
  pnpm-deps hash mismatch.** The 2026-09-19 flake.lock update bumped
  nixpkgs (`ec2d622`→`e554fab`); upstream jellarr (`de530bc`,
  hardwired hash) now fetches different pnpm content → the whole
  `vmtest-e2e.sh` closure fails to build. **Proven independent of the
  i2p-resilience work** (reproduces with the changes stashed).
  Upstream: PR #75 (pnpm pin) closed unmerged, PR #73 (package
  override) open. Fix options: (a) surgical `fetchPnpmDeps`
  hash-substitution overlay (self-healing when upstream updates),
  (b) roll the nixpkgs lock back to `ec2d622` (last green; risk to
  the rust-overlay/dioxus sessions), (c) wait for upstream. Blocks
  T3 of `.specify/specs/i2p-resilience/` — and any L2 claim.
- Dashboard HTML/tests depend on daisyUI/htmx CDNs (vendoring is the
  clean fix).
- `redis_store_round_trip` needs a fresh store (asserts absolute IPs).
- Stale qemu VMs hold ports 2222/443 and poison later e2e runs with
  old systems; `vmtest-e2e.sh` now kills them before booting — never
  trust e2e verdicts from a manual session that didn't sweep qemu
  first.
## Todo

- **I2P resilience path** (`.specify/specs/i2p-resilience/proposal.md`
  — proposal, not started): two slices — (1) dex issuer → loopback
  (`http://127.0.0.1:5556/dex`) + per-path Caddy rewrite vhosts incl.
  a plain-HTTP `.i2p` vhost, hermetic L2 for both login paths; (2)
  i2pd + hosts.txt + origin-aware dashboard I2P section. Jellyfin
  only; CryptPad out of scope (SPA + own origin model). ADR-031
  pending.
- **Path-based routing — SHIPPED 2026-09-26 (ADR-034, see Works).**
  Residual follow-ups: (1) I2P `hosts.txt` collapse + dashboard I2P
  section — deferred to the i2p-resilience arc (the i2p matrix rows
  already derive from the contract); (2) dashboard service links could
  drop the stub hop and use `/<name>` directly (they work today via the
  307 stubs); (3) browser-test Seerr sessions on the LAN port-site and
  decide forgejo's `session.COOKIE_SECURE` policy for LAN-HTTP sessions
  (A9 finding in the proposal).
- **Accounts + machine enrollment** (`.specify/specs/accounts-and-pairing/`
  — proposal **amended 2026-09-16**, **T4–T9 done + proven**,
  T10–T11 pending): next is the single-VM edge+client vmtest
  foundation (T10: `vmtest.nix` enables the real client module + an
  in-VM edge) then the onboarding e2e (T11: invite → approve → tunnel
  → curl through the /128) — the arc's gate.
- **Upstream CryptPad subfolder issue** (`.specify/specs/cryptpad-subpath-issue/`
  — research complete 2026-09-25, issue not drafted): appeal upstream
  for an opt-in documented path-prefix mode (3-claim structure +
  drafting rules in the proposal); interim plan is the factory
  `routeStyle` origin-bound exception for cryptpad in the path-routing
  refactor.
- Config editor hardening: binding insertion for missing fields,
  `public` toggle.
- Dashboard as a real NixOS module (`fortress.dashboard.enable`).
- v2.restic encrypted backups. Nextcloud service module.

## Pre-implementation converge (2026-09-05)

Base check before the accounts-and-pairing arc
(`.specify/specs/accounts-and-pairing/proposal.md`, T1–T11). All green:
`status.sh` 3/3, `cargo test --workspace` 151/151, `nix flake check`
all-pass (incl. `edge-forward` L2). Drift found: **`vmtest.nix` still has
no `services.fortress-client` / in-VM edge** (STATUS "Next move 7" never
landed) — added as proposal T10, the foundation for the onboarding e2e.
Also: **amon-sul deleted** from the repo + flake; its STATUS entries
(matrix-synapse, jellarr bootstrap, admin env wiring, migration) are
moot.

## Current focus

**NEXT SESSION — T4 then T6 of the topcoat arc** (T5 landed — see Works;
the `/api` contract is live against the domain). Ordered:
1. **T4**: `/machines` dashboard as topcoat `#[shard]`/`#[procedure]`
   with the session-auth'd owner ops (`invites_of`, `machines_of`,
   `invite_approve`/`invite_deny`/`invite_revoke` behind the session
   cookie). Explicit fallback if shards disappoint (topcoat's client
   reactivity is self-described as early-stage): plain form POST + full
   page reload. The dashboard must not be able to block the arc.
2. **T6**: site binary gains the real forwarder + real WG/DNS (today
   `main.rs` hardwires `MockWgClient`/`MockDnsApiClient` and boots with
   the dummy edge key), an `--addr` flag exists but is unused by nix,
   `--dummy` stays debug-builds-only. This replaces the
   `DUMMY_EDGE_WG_PRIV` boot identity with the store-held production key.
3. **T7 cutover**: `nix run .#dashboard-dev` runs only the new stack
   (`edge` process deleted from `nix/dev/process-compose.nix`, `site`
   the single server on :8081); `fortressEdgePkg` →
   `systemConfigs.edge` points at the site binary.
4. **T8**: delete poem's web+API (`web.rs`, `auth.rs`, poem deps, the
   `fortress-edge` binary) **and** the dioxus/wasm tier (dioxus dep,
   `web` feature, crane wasm leg, wasm-bindgen 0.2.127 shim, `dx` loop).
   `crates/web-ui`'s momenta rsx survives — `crates/client`'s `:3000`
   dashboard still uses it and stays poem (out of scope).
5. **Final gate**: `scripts/vmtest-e2e.sh` PASS + `edge-forward` L2 PASS
   — still blocked by the jellarr pnpm landmine below.
6. **Toolchain debt still open nix-side**: the flake's
   `nix/packages/site/default.nix` pins `rust-bin.stable."1.97.1"` and
   the site crate (edition 2024, topcoat) will not build until bumped to
   `"1.98.1"`. devenv is fixed; the nix build is not.

**T2a landed (2026-09-20)**: the dioxus site now serves `/register` +
`/login` with **real account logic embedded in-process** — a
server-gated `fortress-controlplane` dep; the site server main boots
a *forwarder-free* `ControlPlane` (mock WG/DNS + dummy subnets — the
account methods are pure Redis+mailer and never touch the forwarder,
which stays the edge's job) and injects it into each request's axum
extensions; dioxus `#[server]` fns `signup`/`verify`/`login`/`logout`/
`current_session` (bodies `#[cfg(feature = "server")]`-gated, so the
wasm tier never compiles the controlplane) replace the poem form
POSTs. **Fullstack ergonomics, no htmx**: the pages hold `use_signal`
form state and re-render from typed outcomes; the session cookie is
set via `FullstackContext::add_response_header`. The landing's
`logged_in`/email nav + hero CTA are wired through `current_session`
via `use_server_future` (SSR resolves it in-process; the client
re-checks after hydration). **Proof**: `cargo test -p fortress-site`
= 9/9 including `signup_verify_login_logout_fullstack_round_trip`
(run with `REDIS_URL=redis://127.0.0.1:6379`, 2026-09-20) — the whole
lifecycle against the new surface, asserting the HttpOnly cookie, the
signed-in SSR landing, and the logout clear. Shared cookie + error
helpers moved to public controlplane exports (`read_cookie_from_headers`,
`session_cookie_header`, `account_error_message`, `SESSION_COOKIE`).

**Deferred / superseded**: the dioxus T2b+T3 arc is **cancelled** — the
presentation layer moved to topcoat (see the Works entry). The
hydration proof is moot: there is no wasm tier to hydrate, and the auth
surfaces are Post/Redirect/Get so they work with JS disabled. The
`/etc/nix/machines` broken `ssh://vermissian` remote-builder entry
(root host key) still costs a failed-SSH retry on every nix build —
operator fix pending. **Disk pressure (2026-09-22)**: the box hit 100%
mid-session; `target/debug` alone is 34G. A `cargo clean` reclaims it
at the cost of a full rebuild — operator call.

**Ship the single-node edge.** The two-node HA pair (edge-ha arc,
ADR-029) was **cut before ship (2026-09-14)** — pre-customers, the
reliability investment was a guess, and the customer-side (home box,
ISP) is the bigger undebuggable downtime pool either way. The edge is
**ONE Hetzner box in `hil` (Oregon)** with ADR-025 addressing (box's own
routed `/64`, customer `/128`s carve from it), the WG dial-out +
control-plane website on the box's own IPv4, DNS at **proletariat.tech**
(operator confirmed 2026-09-14; an interim wiring to `interdim.net` in
the tofu was corrected back — the zone ships now in the same apply),
and the **external managed Redis retained** (`REDIS_URL` secret,
`rediss://`) as the control plane's persistence — a dead box is a
rebuild, not a data-loss event. The floats, lease, and HA wiring are
**deleted from the tree** (git history preserves them); T5–T8 of the
edge-ha proposal are cut, T5 redefined as the single-node ship build. Deferred HA paths (the lease; provider BGP
dual-announcement of a customer-owned `/48`) documented in ADR-029.
**What shipped (2026-09-14):** tofu rewritten — floats removed
(`main.tf` single `hcloud_server.edge`, box `/64` addressing), `dns.tf`
reconciled to `proletariat.tech` (source no longer drifts), `render.tf`
passes `domain`, location default `hil`; `edge.nix.tftpl` Caddyfile now
`${domain}` from var + `--ipv6-iface eth0` retained (the customer-`/128`
reachability fix — the template had silently dropped it, a tripwire
that would have re-broken `/128` reachability on re-render);
`provision-edge.sh` restarts `edge-control-plane` (not the dead
`fortress-edge` unit name); `system-manager/edge.nix` re-rendered.
Proof: `tofu validate` PASS, `edge.nix` parses, `edge-store-wiring`
tripwire green against the new template.
**Next:** provision the `hil` box via `provision-edge.sh` (full
teardown license: hel1 box + store data disposable; customers
re-register), verify the external store TLS PONG + `example123`
reachable, then write the rebuild runbook (the replacement for the
failover test).

accounts-and-pairing (`.specify/specs/accounts-and-pairing/`) — **T3
done (web UI + `/api` namespace split, 2026-09-06)**, T4–T11 pending.
Email account (magic-link verify + reset via SMTP) → many machines at
flat `<machine>.proletariat.tech`; owner generates an invite URL, the
machine auto-enrolls, owner approves + names it on `proletariat.tech`
(amended 2026-09-16 — see the proposal's amendment log), box gets
its route + device token (closes ADR-025's deferred gap); account
deletion unwires, never wipes.

**In progress — T3 (web UI). Landed so far:**
- **T1 done (Mailer + SMTP secrets):** `Mailer` trait (`send(to,
  subject, body)` — the SMTP-submission self-host seam), `SmtpMailer`
  (lettre, STARTTLS+AUTH), `ConsoleMailer` (no-SMTP fallback),
  `MockMailer`; `SMTP_*`/`MAIL_FROM` optional secrets in
  `secretspec.toml` (absent → console). Proof: controlplane tests
  (mail + secret contract) + `nix flake check` all-pass.
- **Verification emails can be resent (2026-09-16):** a lost
  verification link was a dead end — login refused ("verify first"),
  re-signup refused ("already exists") — so `resend_verification`
  (`ResendVerifyOutcome::{Sent,AlreadyActive,UnknownEmail}`) mints a
  fresh single-use link for a pending account, and the UI now routes
  there: login on an unverified account renders a "Verify your email"
  page with a resend form; `/auth/resend-verify` (GET form + POST) and
  `POST /api/users/resend_verification` cover web + API; signup's
  duplicate-email error and the login page point at it. Proof: 81
  controlplane tests green vs live Redis (incl. new
  `resend_verification_outcomes_cover_pending_active_unknown` +
  `resend_verify_web_round_trip`); clippy clean for touched code.
- **Reset outcome is explicit (2026-09-16):** signup already leaks
  registration status (user-visible "already exists" error), so
  reset-path silence was enumeration theater — now both the API
  (`POST /api/users/reset_password` → "no account with that email —
  sign up first") and the web forgot form (distinct "No account with
  that email" page linking to /register) tell the truth; unknown emails
  send nothing and infra errors surface as errors instead of a faked
  success page. `ResetOutcome`/`ForgotOutcome` enums carry it. Proof:
  79 controlplane tests green vs live Redis (incl. renamed
  `reset_unknown_email_is_explicit_and_sends_nothing` + web
  round-trip asserting both pages); clippy clean for touched code.
- **Resend relay provisioned (2026-09-16):** SMTP_* secrets in the
  sops store (SMTP_HOST/USER/PASS — no provider-specific
  RESEND_API_KEY name), declared in the root toml's `provisioning`
  profile + `provision` scope; `provision-edge.sh` builds edge.env
  locally (0600) and pipes it over ssh, appending SMTP_* only when
  configured (USER/PASS lines only when non-empty — no-auth relays
  stay absent, not empty). DKIM/SPF-CNAME/DMARC rrsets for
  proletariat.tech in `tofu/dns.tf` (tofu validate green; applied on
  next provision run, then verify in the Resend dashboard). Proof:
  `bash -n` green + `secretspec export -S provision` emits all seven
  keys incl. SMTP_*; live apply pending next provision run.
- **T2 done (Account model + sessions + auth + reset):** Redis keys
  `fortress:account:{email}` (AccountRecord JSON: username, status
  pending→active, bcrypt password hash, plan), `fortress:username:{u}`
  (SETNX uniqueness), `fortress:verify|reset:{token}` (24h, GETDEL
  single-use), `fortress:session:{token}` (7d). signup/verify/login/
  logout/reset + no-account-enumeration on reset, rolled-back signup on
  mail failure. Proof: 56 controlplane tests green against a live Redis
  (incl. `redis_store_round_trip`, now idempotent across reruns via a
  cleanup preamble); `nix flake check` all-pass.
- **Zine UI library extracted; every surface migrated; CDN + daisyUI
  deleted — 2026-09-17.** New shared crate `crates/web-ui`: design tokens
  (`ZINE_CSS`), loud-ornament layer (`LOUD_CSS`: grain, halftone, tears,
  marquee), momenta components (stamp, buttons, card, code_block, field,
  tick_list, ticker, torn), `shell(title, variant, body)` with
  `ShellVariant::{Loud,App}` intensity dial, and pinned vendored assets
  inlined via `include_str!` — Tailwind browser build 4.3.3 + htmx 2.0.10
  (`assets/*.js`); Tailwind classes stay, daisyUI is gone, **zero
  third-party origins at runtime** (works offline on the box). All
  controlplane pages (landing=Loud, auth+machines dashboard=App —
  machine states render as rubber stamps) and all client local
  dashboard pages use it. Preview tools:
  `cargo run -p fortress-controlplane --example landing_preview` /
  `auth_preview`, `cargo run -p fortress-client --example
  dashboard_preview`. Tripwires: `pages_have_no_external_asset_origins`
  in both crates' test modules — after the blind judicial review they
  render every page (11 controlplane + 3 client) and ban all external
  URL shapes (`<script/src="http`, `<img src="http`, `<iframe src="http`,
  `<link href="http`, `url(http`, bare `cdn.jsdelivr` /
  `cdnjs.cloudflare.com`; the vendored assets' provenance comment
  headers were stripped to make that grep false-positive-free), and
  assert the machines page stamps invite statuses.
  Proof: 82 controlplane (re-run with REDIS_URL=redis://localhost:6379
  so the Redis-backed flow tests execute) + 72 client + 6 web-ui tests
  green; `scripts/status.sh` 3 checks PASS; screenshots reviewed
  (`/tmp/opencode/zine-desktop-v3.png`, `zine-index.png`,
  `zine-editor.png`, `zine-machines-v2.png`, `zine-login.png`,
  `zine-mobile.png`). Spec: `.specify/specs/zine-ui-library/`.
  Judicial review (blind subagent, 2026-09-17): PASS WITH AMENDMENTS —
  all follow-ups applied (logged-in hero CTA restored to `/machines`
  with a href assertion; tripwires strengthened; provenance headers
  stripped; stale daisyUI comments fixed).
- **Landing restyled to paper-zine agitprop — 2026-09-15.** Red/ink/paper
  palette, grain + halftone texture, stamp badges, hard-shadow cards,
  torn dividers, marquee ticker; all type monospace/uppercase via CSS
  (DOM text unchanged, so content tests still pass). Custom CSS lives in
  `LANDING_CSS` in `crates/controlplane/src/controlplane/web.rs`
  (daisyUI theme classes no longer used on the landing). Proof: 64
  controlplane tests green; screenshots `/tmp/opencode/zine-desktop.png`
  + `zine-mobile.png` reviewed.
- **T3 done (web UI + the `/api` namespace split) — 2026-09-06.**
  Pages (momenta+daisyUI: landing, register, login, forgot, reset,
  verify, message) + handlers + session-cookie
  (`fortress_account_session`, HttpOnly+Lax) in
  `crates/controlplane/src/controlplane/web.rs`. Verify-token GET page
  deliberately does NOT consume the token (email-prefetch guard); POST
  `/auth/verify` consumes. **The whole API moved under `/api/` as ONE
  poem-openapi service** (`UsersApi` + `WireguardApi` + `HealthApi`
  merged): swagger UI at `/api/docs`, spec at `/api/openapi.json`
  (`.server("/api")`), grouped by resource —
  `/api/users/{register,login,verify,reset_password,reset_password/confirm}`
  (public, session token IS the auth), `/api/wireguard/{new,pubkey}` +
  collection `/api/wireguard` list + `/api/wireguard/:username` delete
  (AdminKey), health at `/api/healthz` `/api/readyz` `/api/status`
  (health is NOT a separate service — two poem-openapi services collide
  on an internal `/*--poem-rest` catch-all in one route tree, so one
  service, one doc). Web owns the root (`/`, `/register`, `/login`,
  `/verify`, `/reset`, `/auth/*`). Operator provisioning moved to
  `POST /api/wireguard/new`; `edge-forward` L2, the spec-gate tests,
  and the provision script echo updated. `AppState` (shared deps) moved
  from web.rs to mod.rs; users-API handlers read it (with a fallback to
  the process globals) so tests inject mocks without fighting the
  singletons. Proof: 63 controlplane tests green incl. new
  `api_users_round_trip` (register→verify→login→reset via the JSON API
  with injected deps) + `spec_gates_protected_ops_and_leaves_public_ops_open`
  (asserts the `/api` server base + AdminKey gating + unguarded
  `/users/*`); full workspace 175 tests green.

Fixed: the control plane's Hetzner DNS client used the deprecated DNS
Console API (`dns.hetzner.com/api/v1`, `Auth-API-Token`), which Hetzner
shut down (migrated to the Cloud DNS API `api.hetzner.cloud/v1/zones/*/rrsets`
+ Bearer, 2026-05). DNS-on-signup silently failed. Rewrote the client and
added L0 tripwires (`hetzner_base_is_cloud_api`,
`rrsets_response_deserializes_cloud_api_shape`,
`new_rrset_serializes_cloud_api_shape`); `cargo test -p fortress-controlplane`
PASS. Also fixed `edge.nix.tftpl` (redis StateDirectory + `LANG=C.UTF-8`;
fortress-edge `path = [ wireguard-tools ]`) and `provision-edge.sh` (wg
full-path on the non-interactive SSH PATH).

Wired the customer box's **dashboard admin login** (`FORTRESS_ADMIN_PASSWORD_HASH`)
into `services.fortress-client.adminPasswordEnvFile` — the dashboard
(control plane of the box) was running in Dev mode (no auth) because Nix
never passed the env var the Rust code already reads. Added the option to
`client.nix`, wired `/etc/fortress-admin.env` in `amon-sul.nix`, and added
`fortress-admin-password-hash` to the sops inventory (T7 home). amon-sul
has since been deleted from the repo + flake.

## amon-sul first deploy (2026-08-25) — found & fixed

First `nixos-rebuild switch` on the box activated but failed (exit 4).
Root causes, all fixed in this repo:

- **`openssl: command not found`** in `fortress-cryptpad-oidc-secret` and
  `fortress-jellyfin-oidc-secret`. Those service scripts call bare
  `openssl` with no `path`. Fixed by adding `path = [ pkgs.openssl ]`
  to both (`integrations/cryptpad-oidc.nix`, `integrations/jellyfin-oidc.nix`),
  matching the existing `services/jellyfin.nix` precedent. This also unblocks
  `dex` (its `BindReadOnlyPaths` requires the secret files these create) and
  `jellyfin` (failed as a dependency of the oidc chain).
- **`matrix-synapse`**: the nixpkgs module defaults `settings.database` to
  `psycopg2`/`matrix-synapse` even when postgres is disabled, so the homeserver
  pointed at a socket that was never started. Fixed by enabling
  `services.postgresql` with `ensureDatabases = ["matrix-synapse"]` +
  `ensureUsers` (`ensureDBOwnership`, this nixpkgs renamed `ensurePermissions`)
  in `custom/matrix.nix`. Reuses the legacy `/var/lib/postgresql` data dir.
- **`wg0`**: the write of `/etc/wireguard/fractal-private.key` did not persist
  on the box. **Operational** — must be re-written before the re-switch.
- **DNS dead**: `/etc/resolv.conf` came up with `options edns0` and **no
  `nameserver` lines**. Root cause: `networking.useDHCP` was still `true`
  (from `hardware-configuration.nix` `mkDefault`, never overridden) on a fully
  static interface — dhcpcd managed resolv.conf, never leased, and dropped the
  explicit `networking.nameservers`. Fixed by `networking.useDHCP = false` in
  `amon-sul.nix`; verified the rendered `localCommands` now run
  `resolvconf -m 1 -a static` with `nameserver 8.8.8.8`/`1.1.1.1`.
- `jellarr-api-key-bootstrap` and `fortress-client` being absent on the box
  were symptoms of the half-completed `switch-to-configuration`, not separate
  bugs; a clean re-switch recreates all units (verified the client unit renders
  with `EnvironmentFile=/etc/fortress-admin.env`).

## amon-sul second deploy (2026-08-25) — partial

After re-push + re-switch: **postgresql, dex, jellyfin-oidc, cryptpad-oidc,
fortress-client all started** (the openssl + postgres fixes landed). Three
left down:

- **matrix-synapse**: postgres up, but synapse aborts —
  `IncorrectDatabaseSetup: collation 'en_US.UTF-8' should be 'C'`. The legacy
  DB was created en_US.UTF-8; recreating would destroy data. Fix (in working
  tree, NOT yet deployed): `database.args.allow_unsafe_locale = true` in
  `custom/matrix.nix`. Pending re-switch.
- **wireguard-wg0**: `fopen: No such file or directory` — key file
  `/etc/wireguard/fractal-private.key` not present. **Operational**: write it
  (key `RfSaKgWjOFWzSASyOPxfcBNYafoudDNDMgzWDOm951E=`), then `systemctl start
  wireguard-wg0`.
- **jellarr-api-key-bootstrap** (exit 1): its script does
  `systemctl stop jellyfin` then a `sqlite3` INSERT then
  `systemctl start jellyfin`; the INSERT fails so `set -e` exits **leaving
  jellyfin stopped** (jellyfin shows `inactive`). Needs the actual sqlite3
  error (`sudo sqlite3 /var/lib/jellyfin/data/jellyfin.db '.schema ApiKeys'`
  + reproduce the INSERT).

## Edge public-surface gap + agreed architecture (2026-08-25)

- **Edge services are healthy** (`fortress-edge` + `redis` active).
- **No public control-plane surface exists**: the API listens on
  `0.0.0.0:8081` (local reach 200, no local iptables/ufw) but the **Hetzner
  Cloud Firewall** (`remote-infra/tofu/main.tf:37`) only opens 22/80/443/51820
  UDP/ICMP — so `:8081` is dropped off-box. `:9090` health is localhost-only.
  `::3:80/443` is the forwarder fronting fractal (correct), not a public server.
- **Agreed fix**: add **Caddy to the edge** serving `proletariat.tech` over
  `https://proletariat.tech` (A `62.238.111.21` + AAAA `2a01:4f9:c014:2c44::1`),
  reverse-proxying `127.0.0.1:8081`. IPv6 canonical choice = **`subnet::1`**
  (`::` is subnet-router anycast owned by Hetzner's gateway; `::1` reads as
  loopback). Customer `/128` allocator starts at `::2`+ so `::1` is free.
  Code lives in `remote-infra/tofu/templates/edge.nix.tftpl` + `dns.tf`.
- **DONE — edge Caddy deployed (2026-08-26)**: Caddy added to
  `edge.nix.tftpl` + `render.tf` (passes `edge_ipv4`/`edge_primary_v6`), unit
  binds IPv4 + `::1` only (never shadows the forwarder's `::3`), proxy →
  `127.0.0.1:8081`. Applied via system-manager switch; `https://proletariat.tech`
  now serves real Let's Encrypt cert (`CN=proletariat.tech`, HTTP-01 verified) and
  `https://proletariat.tech/pubkey` returns `lX+5lGEF1qDJEag13Kymyxy/SJH63LPxKTvMg50WE2E=`.
  Proof: curl over IPv4 + `openssl s_client` verify OK; `ss` shows Caddy on
  IPv4+`::1` and forwarder on `::3` coexisting.
- **DONE — health + swagger over the same HTTPS surface**: Caddyfile routes
  `/healthz` `/readyz` `/status` → `127.0.0.1:9090` (the health server stays
  localhost-only behind Caddy) and everything else (`/docs` swagger UI,
  `/openapi.json`, `/pubkey`, `/signup`, ...) → `127.0.0.1:8081`. All reachable
  at `https://proletariat.tech/*`. Proof: `/healthz`→200 "ok", `/status`→200
  (live forwarder state), `/docs`→200 full swagger-ui HTML (1.6MB). Note:
  after re-render + system-manager switch, a `systemctl restart caddy` is
  needed — system-manager doesn't restart a service whose unit definition
  didn't change, so the new Caddyfile wasn't picked up until the manual restart.
- **DONE — health merged into the API handler (code-level, supersedes the
  Caddy route split)**: `HealthApi` (in `crates/core/src/health.rs`) is now
  public with `new(status_func)`; `fortress_controlplane::app()` builds one
  poem-openapi service from `(ControlPlaneApi, HealthApi)`, so the edge serves
  `/healthz` `/readyz` `/status` and the control-plane API (swagger `/docs`,
  `/openapi.json`, `/pubkey`, `/signup`) from ONE listener on `:8081`. The
  `--health-addr` flag and separate `:9090` edge health server are gone (the
  customer-box *client* still runs `HealthServer` on `:9090` for itself).
  Caddyfile reverted to a single `reverse_proxy 127.0.0.1:8081`. Proof: cargo
  tests incl. `health_merged_into_api_handler` + all 23 `nix flake check`
  checks (incl. `edge-forward` nixosTest, updated to probe edge health on
  `:8081`); live `https://proletariat.tech/{healthz,readyz,status,pubkey,docs}` = 200.
- **Systemd unit-name corruption on the edge box (found during deploy)**: the
  `fortress-edge` systemd unit NAME PREFIX is poisoned on the box — systemd
  starts such a unit at boot but un-tracks it on the first `daemon-reload`
  (`is-active`/`cat`/`start` all report "not found"), so system-manager
  switches could never restart it. Verified: identical unit content loads fine
  under other names (`zzz-edge-a`, `cocoedge-diag`); only `fortress-edge*` is
  refused, surviving daemon-reload/reexec/symlink-recreate/reboot. **Fix**:
  edge service renamed to `edge-control-plane` in `edge.nix.tftpl`, which is
  tracked and survives reload. Deploy gotcha to remember for this box.
- **Agreed architecture for keygen**: fold WG keygen into the **dashboard**
  (client generates + persists its own keypair, sends only the pubkey to the
  edge; edge never holds customer private keys). Dashboard fetches the signup
  from the public `proletariat.tech` endpoint in the same step, then manages wg0
  (drop the NixOS wg0 module + operator key-file step). `POST /signup` changes
  to accept a client `public_key` (still AdminKey-auth'd for now; future =
  website-signup device token). This also kills the edge-holds-private-keys
  smell and the `fopen` fragility.

## Live infra state (as of 2026-09-14)
- Old hel1 edge box (`162615675`) **destroyed** via apply; AWS option dead, Hetzner `hil` (Oregon) is the destination.
- First `apply` failed mid-run: `hil` does not carry `cx23` (US locations are `cpx*`/`ccx*` only; verified via Hetzner API). Fixed: `server_type` default now `cpx11` (variables.tf + tfvars comments). Proof: server_types API listing filtered on `hil`.
- Next operator action: re-run `provision-edge.sh` (tofu re-applies, then full config lands). The box gets fresh IPs; re-render + DNS follow automatically.
- Teardown license stands: customers re-register on the new `hil` box; store data intact.

## Session start checkpoint

1. **DONE — edge Caddy + `::1` public surface** (`https://proletariat.tech`).
2. **DONE — `/signup` accepts a client WG key, idempotent + rotates**
   (`.specify/specs/client-supplied-wg-key/`): the edge no longer generates
   or holds a customer private key — the client supplies its own `public_key`
   (ADR-025). Same-key re-signup = idempotent no-op; diff-key = rotation.
   Proof: cargo + `nix flake check` 12/12 + live edge (201/200/rotation).
3. **DONE — dashboard-keygen: client owns wg0 + its key**
   (`.specify/specs/dashboard-keygen/`): `fortress-client` generates +
   persists its own keypair (`/var/lib/fortress/wg-private.key`, 0600) and
   brings up wg0 itself. Deployed to amon-sul.
4. **DONE — Jellyfin on amon-sul is up and REMOTE access works.** Full path
   live: idol → edge `2a01:4f9:c014:2c44::3:443` → WG → box `10.10.0.3:443`
   → client forwarder → Caddy → Jellyfin; `curl https://jellyfin.fractal.
   proletariat.tech` → HTTP 200 (Jellyfin web UI). Three bugs found + fixed this
   arc:
   - **Storage**: `/dev/sda1` (btrfs) was unlabeled so `LABEL=tank` (`/media`)
     didn't mount → subvolumes → jellyfin dependency cascade. Fixed by
     relabeling + migrating NVMe `/media/entertain` into the pool, and
     patched `storage/btrfs.nix` to **ensure** the label on an existing pool
     (was a silent-failure seam).
   - **Client idempotency**: `addr_present` compared `10.10.0.3` against the
     rendered `10.10.0.3/24`, so a restart re-added the address and crashed.
     Fixed (strip prefix) + regression test. This is why the box crash-looped
     after every rebuild/restart.
   - **Caddy wildcard bind**: Caddy bound `*:80/443`, colliding with the
     client forwarder's `10.10.0.3:80/443` (EADDRINUSE) → remote dead. Fixed
     by binding every public vhost to `127.0.0.1 ::1` (factory in
     `_contract.nix` + the custom matrix vhost) + an L1 assertion.
5. **DONE — customer `/128` reachability (edge, deployed).** `IPV6_FREEBIND`
   alone does NOT make an in-subnet `/128` deliverable: `2a01:...::3` was
   unreachable from the internet (not a local address; forwarding off) while
   the edge's own `::1` worked. Fixed in code: the forwarder adds each
   customer `/128` as a local address on `--ipv6-iface eth0`
   (`ensure_ipv6_local`), re-added on reconcile-on-boot so an edge reboot
   re-installs it. Deployed via system-manager; confirmed the running binary
   carries `--ipv6-iface eth0` and `::3` is in the local table.
   Proof: `cargo test` (workspace green) + `nix flake check` 12/12 +
   `curl https://jellyfin.fractal.proletariat.tech` = 200 (live, e2e).
6. **DONE + VERIFIED LIVE — dex login + cryptpad dead were ONE bug: missing
   TLS certs** (fix deployed in commit `2b5d7d2`, applied to the box).
   `caddy.service` now orders after `fortress-client.service`
   (`_contract.nix`); L1 tripwire in `vmtest-wiring`. Live proof: idol →
   auth discovery 200, SSO `Start/dex` follows redirects to the dex login
   page (final 200), cryptpad 200; user confirmed working SSO login.
7. **IN PROGRESS — vmtest fidelity + vermissian runner.** The main e2e
   still doesn't exercise the tunnel/forwarder/ACME bug class (vmtest never
   enables `services.fortress-client`; only `amon-sul.nix` does). Landed
   this session:
   - **Tripwire written, NOT yet executed**: `vmtest-bootstrap.sh` now
     asserts every vhost (auth/jellyfin/cryptpad/radarr/sonarr/lidarr/
     prowlarr) presents a cert that verifies against the VM trust store
     (`openssl s_client -verify_hostname`, catches certless-vhost = the
     incident-6 class); `openssl` added to vmtest packages. First real
     execution = next e2e run — unverified until then.
   - **vermissian runner ready**: reconciled `~/fortress` to origin/main
     (old commits preserved on local branch `backup-vermissian-wip`);
     24c/61G/152G free; `nix flake check` run started (first closure,
     warms the store).
   - **First vermissian e2e ran — FAIL(10), all ten = suite bugs, VM
     healthy.** Decomposition: 7× TLS false-positive (`-CApath` vs
     bundle — NixOS `security.pki` extras land only in the bundle file;
     fixed to `-CAfile`); 1× jellarr timeout (check read
     `ActiveEnterTimestampMonotonic`, which systemd zeroes on
     deactivation — condition unsatisfiable for a completed oneshot;
     fixed to `ExecMainExitTimestampMonotonic`); 2× services-list bugs
     (`is-active || echo missing` corrupted the "activating" state;
     late-starting oneshots raced the snapshot — list is now always-on
     services only, pipeline loop owns the oneshots). Bonus find:
     the OIDC-button check grepped `web/index.html`, but Jellyfin
     10.11's SPA serves branding via `Branding/Configuration` — fixed
     to assert that endpoint. Key positive: **the jellarr pipeline
     works on fresh boot** (apply complete; the old jellarr P0 is gone
     — the failure was the suite's own check). Fixed suite verified
     all-green against the live VM. Official PASS stamp awaits a fresh
     `vmtest-e2e.sh` run.
   - **Next**: single-VM edge+client in `vmtest.nix` — enable the real
     client module + an in-VM edge unit (mirror the `nix/tests/edge/`
     edge node: Redis, wg0, secrets env, admin key = sha256
     "test-admin-key"); client forwards `10.10.0.x:80/443 →
     127.0.0.1:80/443`; bootstrap does the `/signup` itself (reads the
     client's persisted pubkey) then curls the customer `/128:443`
     through the tunnel. Stretch: pebble as ACME CA for full ACME-mode
     fidelity. Then `scripts/vmtest-e2e.sh` green on vermissian = v2 gate.
8. Still broken on amon-sul (independent): `matrix-synapse` (crashes at
   boot; its vhost has a cert but 502s — needs journal), `jellarr-api-key-
   bootstrap` (re-check now jellyfin is up), and the client dashboard
   (EADDRINUSE on its own port — non-fatal). Revisit after 6 is verified.

v2 gate: a clean `scripts/vmtest-e2e.sh` PASS — the last remaining
failure is the jellarr P0.
