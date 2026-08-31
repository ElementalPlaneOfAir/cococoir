# dashboard-apply — the dashboard edits + applies the box's config

Status: proposal.

## Premise

User interview (2026-08-29): "It should absolutely be able to go ahead
and change and modify the configuration on the machine through the
dashboard. Everything there is done through HTMX and isn't wired up."
Signup is deprioritized ("probably fine for now"). Access model
(final): the public dashboard vhost (`dashboard.<baseDomain>`) is the
mandatory product path; local-serving research is deferred (see
"Access model"). The observability spine (htmx-dashboard
arc) stays a separate, later arc.

Today the dashboard is dead on any deployed box, for three verified
reasons:

1. **It cannot bind.** `dashboard::serve` hardcodes `0.0.0.0:3000`
   (crates/client/src/dashboard/mod.rs:469); cryptpad owns :3000 on
   amon-sul → EADDRINUSE → the dashboard task exits (logged, non-fatal).
2. **It is unreachable.** No Caddy vhost, no firewall port (22/80/443
   only), no TLS.
3. **Its one feature consumes nothing.** `COCOCOIR_CONFIG_PATH` is
   never set in `client.nix` → the editor falls back to a
   repo-relative path that does not exist on the box. Even with a
   writable file, nothing on the box applies an edit: the flake lives
   in the operator's repo (ADR-013); the box has no checkout, no
   rebuild path. The editor is a dev-loop tool wearing a production
   costume.

Cost of not building: every customer config change (toggle a service,
manage a user) routes through the operator over SSH forever — the
exact bottleneck the BUISNESS-PLAN says cococoir exists to remove.
The dashboard remains a dev toy.

This arc supersedes the config-editor proposal's "deliberately out of
scope: apply" line. It does NOT build the observability content
(services up/down, probes, logs) — that is the htmx-dashboard arc,
sequenced next.

## Acceptance criteria

- [ ] **L0** `cargo test -p cococoir-client` green. New tests: the
      `-dashboard-addr` flag parses and defaults to `127.0.0.1:9091`;
      the demo routes (`/hello/:name`, `/update`, `/session*`) are gone
      (404); the apply runner against a mock `CommandRunner` covers
      success (returns log tail), failure (propagates exit status +
      tail), start-while-running (rejected, no second rebuild); the
      login rate limiter trips and resets. Editor round-trip tests
      unchanged (same parser, same schema, only the path source moves
      to env/flag wiring).
- [ ] **L1** `nix flake check` green, including new vmtest-wiring
      tripwires (evaluating both vmtest AND amon-sul):
      - dashboard vhost rendered ⟺ client enabled ∧ baseDomain set ∧
        `adminPasswordEnvFile != null` (no password → no vhost —
        fail-closed exposure);
      - the vhost's `reverse_proxy` target equals the client unit's
        `-dashboard-addr` value (port drift fails the build);
      - `cococoir-apply.service` exists when the client is enabled;
      - client unit `ReadWritePaths` contains `/etc/cococoir` and
        `Environment` carries `COCOCOIR_CONFIG_PATH=/etc/cococoir/nixosConfigurations/<host>/dashboard.nix`.
- [ ] **L2** `scripts/vmtest-e2e.sh` PASS including new bootstrap
      assertions: `https://dashboard.vmtest.local/` serves through Caddy
      with a cert that verifies against the VM trust store (the
      incident-6 check pattern); unauthenticated GET redirects to
      login; an authenticated session renders the editor; a POST save
      mutates `/etc/cococoir/.../dashboard.nix` on disk (file diff) AND
      the edit is visible to the flake (`nix eval` a probe option
      post-edit returns the new value — written ≠ evaluated is the
      silent-failure seam);
      `cococoir-apply.service` is present (`systemctl cat` succeeds)
      but NOT executed in the VM (no in-VM rebuild — hermeticity).
- [ ] **Manual (the apply gate)** on amon-sul: `nix run
      .#box-sync -- amon-sul`, rebuild, log in at
      `https://dashboard.fractal.interdim.net`, change a service toggle,
      Save, Apply, watch the rebuild succeed and the change go live
      (service active / vhost present). Rollback via the boot menu
      verified once. Proof recorded in docs/STATUS.md.

## Smallest version

The box gets a flake checkout at `/etc/cococoir` (delivered by a new
`nix run .#box-sync -- <host>` app). The machine config imports a
per-machine `dashboard.nix` (bare attrset — the exact file shape the
editor already parses; zero parser changes). The editor edits that
file in place (path from a default derived from `networking.hostName`,
no new customer option). Apply is a dedicated oneshot systemd unit
`cococoir-apply.service` running a FIXED argv
(`nixos-rebuild switch --flake /etc/cococoir#<host>`); the dashboard
starts it via `systemctl start --no-block`, polls
`systemctl is-active` + tails the unit journal, and renders an HTMX
progress fragment ending in success/failure. The dashboard vhost
(`dashboard.<baseDomain>`, TLS via `cococoir.tls`, loopback bind, proxied
to the dashboard's loopback port) renders only when the admin password
env file exists. The dashboard moves to `127.0.0.1:9091` (fixes the
cryptpad collision), assets are vendored (no CDN), and the demo routes
die.

**Access model (final, user decision 2026-08-29): the public dashboard
vhost is the mandatory product path** — ordinary users must manage
their system from anywhere, so global access is not negotiable. The
broader local-serving research (mDNS, SVCB/HTTPS-RR, browser
rebinding experiments) is **deferred**. T9 merely resurrects the
box's dnsmasq split-horizon (pre-refactor `b263bf1`) as a dormant
seed for that arc: the box self-resolves via `networking.hosts`
already, and no LAN client points at dnsmasq until the deferred arc
lands the router-side DHCP setting — so T9 is verified by direct
query on the box (`dig @127.0.0.1`), not by any consumer behavior.

Explicitly deferred: Dex-OIDC dashboard auth (named successor to the
shared admin password), a rollback button (NixOS boot-menu generations
cover it), offline-first rebuild hardening (first apply may fetch
inputs; amon-sul has internet), observability content, signup UI, the
customer-flake template + provisioning writes `/etc/cococoir` at
signup, the "system update" button (flake.lock bump + rebuild), and
the fleet flake split (operator boxes → private flake inputting the
product — required before this repo can be public; `amon-sul.nix`
holds LAN IPs, usernames, and edge endpoints).

## Config topology (two flakes)

The apply mechanics are provenance-agnostic: they require a flake at
`/etc/cococoir` exposing `nixosConfigurations.<host>`, plus a
per-machine `dashboard.nix` inside it. Two producers:

- **Product flake (this repo)** — `nix/nixos-modules`, the client +
  dashboard binaries, tests. Published; consumed as a flake input.
  Holds no customer machine config long-term (fleet split, deferred).
- **Customer flake (box-local, `/etc/cococoir`)** — one per box:
  `flake.nix` + `flake.lock` (cococoir pinned) +
  `nixosConfigurations/<host>/{configuration.nix, dashboard.nix}`.
  `configuration.nix` is the customer's hand-wired config (imports
  cococoir's modules, sets hardware/secrets/hostName); `dashboard.nix`
  is the dashboard-editable bare attrset. The dashboard edits ONLY
  `dashboard.nix` (rnix-validated, atomic rename); apply rebuilds
  `--flake /etc/cococoir#<host>` from the pinned input.

Properties this buys:

- Version consistency: the dashboard binary and the option tree it
  writes come from the same pinned cococoir rev — no UI/schema skew.
- Failed eval → failed rebuild → old generation keeps running (switch
  is atomic). Rollback = boot menu.
- Upstream updates are explicit: bump the input lock (deferred
  "system update" button), never implicit drift.

Producers, today vs later:

- amon-sul (dogfood): `/etc/cococoir` is a box-sync mirror of the
  operator repo; `dashboard.nix` syncs back. box-sync is an operator
  tool, NOT the customer mechanism.
- Real customers: OUT OF THIS ARC — the customer-flake template +
  provisioning is its own future arc with its own spike (a template
  flake must be proven to build before anything consumes it); until
  then the operator provisions by hand.
- Fleet split (deferred): operator-owned boxes move to a private
  fleet flake inputting the product.

Trap, and the tripwire it earns: if `/etc/cococoir` is a git repo,
Nix evaluates the git tree — untracked files are invisible to eval
and edits silently don't apply. box-sync therefore excludes `.git`
(plain directory flake), and the e2e asserts the edit is *visible to
the flake* (`nix eval` a probe option post-edit), not merely on disk.

## Alternatives considered

- **Read-only editor on deployed boxes** (foundation-only arc) — case
  for: smallest, zero new risk. Case against: the user chose apply as
  the arc goal; a read-only dashboard still does nothing the customer
  can feel. Rejected by interview.
- **JSON intermediate instead of editing Nix** (machine config does
  `builtins.fromJSON (readFile /etc/cococoir/dashboard.json)`) — case
  for: no Nix syntax leakage. Case against: duplicates the config
  language (the factory owns the option tree, ADR-020), discards the
  built lossless parser, and JSON-in-/etc is a second source of truth
  alongside the flake. Rejected.
- **In-process apply** (client spawns nixos-rebuild directly) — case
  for: no new unit. Case against: forces `ReadWritePaths`/sandbox
  relaxation on the always-on client unit 100% of the time for a rare
  operation; couples apply lifetime to client lifetime; loses
  journal-native logging. Rejected: dedicated unit keeps the client's
  hardening and gives apply its own identity (restart-safe, tail-able).
- **Git repo on the box** (editor commits; full history on-box) — case
  for: real rollback + audit. Case against: a second state store
  (NixOS generations already are the rollback), drift between box git
  and operator repo, and git is not a customer concept. Rejected for
  this arc; box-sync reconciles the one file that matters. Revisit if
  generation-rollback in the UI is ever insufficient.
- **Separate dashboard binary** (the rust-rewrite.md §2 trust-domain
  split) — case for: config/rebuild power isolated from telemetry's
  untrusted input. Case against: ADR-026 collapsed to one binary per
  system; the dedicated apply unit is the structural mitigation that
  matters today. Rejected for now — revisited in the objection and
  when the journald tailer lands in-process.

## Architecture decisions

- **New ADR-028 (lands in PLAN.md with the implementation): the
  dashboard is the box's control plane.** Box-local flake checkout at
  `/etc/cococoir`; per-machine `nixosConfigurations/<host>/dashboard.nix`
  is the customer-tunable surface; apply = dedicated `cococoir-apply`
  unit with fixed argv; the operator's repo stays canonical for
  machine wiring; `box-sync` reconciles (repo → box for everything,
  box → repo for dashboard.nix). This reconciles ADR-013 ("operator
  never edits files on a live machine" — the operator doesn't; the
  customer does, through the dashboard) with ADR-025 ("as much
  complexity as possible stays in the customer dashboard").
- **No new customer-facing option.** Constitution §3/§4: the dashboard
  activates with `services.cococoir-client.enable`; the vhost derives
  from `cococoir.baseDomain`; the port is an internal default
  (`services.cococoir-client.dashboardAddr`, defaulted to
  `127.0.0.1:9091`, never set by a customer — one source of truth for
  both the unit flag and the vhost target).
- **The dashboard vhost is platform-owned, not a factory service**
  (ADR-027 layer split): it has no storage/health/OIDC contract, so it
  is not a `mkCococoirService` — same layer as `tls.nix`. It reuses
  the vhost pattern (`tls` + `bind 127.0.0.1 ::1` + `reverse_proxy`)
  and honors `cococoir.tls`.
- **Config topology is two flakes** — product flake (this repo,
  consumed as a pinned input) + box-local customer flake
  (`/etc/cococoir`). The dashboard/apply stack is provenance-agnostic:
  it needs a flake exposing `nixosConfigurations.<host>` and a
  per-machine `dashboard.nix`; box-sync (dogfood) and provisioning
  (customers) are just producers. See "Config topology".
- **Security posture, stated plainly:** the admin credential is
  root-equivalent (Save writes Nix that `nixos-rebuild` evaluates as
  root). Mitigations: auth fail-closed (existing), vhost gated on the
  password env file (new tripwire — no auth → no exposure), loopback
  bind + Caddy TLS, fixed-argv apply (no form data in any command),
  parser-validated writes only (rnix re-parse before atomic rename),
  and a minimal in-memory login rate limiter. The UI copy should say
  "admin access ≈ root" where credentials are set.
- **Admin-only auth, by construction (not a flaw to fix).** The
  dashboard is reachable ONLY through the single admin credential
  (`COCOCOIR_ADMIN_PASSWORD_HASH` ← `AMON_SUL_MASTER_PASSWORD`),
  deliberately NOT through Dex. The code says it (auth.rs): a Dex
  compromise must never grant box control. So there is no "household
  shared secret = root" problem — Dex users (nicole/brad/…) never
  reach the dashboard; only the box owner holds the admin credential,
  and the owner is the admin. `cococoir.dashboard.adminPassword` is
  not a thing; the env file is the sole gate. This is a deliberate,
  load-bearing separation — see the vhost tripwire that refuses to
  render without it.
- **Residual, honest debt:** the single admin password is the one gate
  between the public internet and `nixos-rebuild`-as-root — no second
  factor, no per-identity audit. Accepted for v1 (the box owner is the
  admin; a strong passphrase suffices). The login rate limiter (T2) is
  the cheap mitigation that ships now. Optional later: TOTP for the
  admin login. NOT the Dex-OIDC-dashboard swap — that would
  deliberately fuse the two identities this design separates.
- **Box-as-DHCP-DNS split-horizon is deferred research, seeded only.**
  Resurrected from the pre-refactor amon-sul (`b263bf1`) as a dormant
  dnsmasq seed (T9): upstream `8.8.8.8`/`1.1.1.1`,
  `address = ["/*.fractal.interdim.net/<lanip>"]`. Nothing consumes it
  in this arc — the box self-resolves via `networking.hosts`, and LAN
  clients only use it once the deferred arc lands the router-side
  DHCP option 6 setting. It cannot break the dashboard because it
  carries none of it.

## Tasks

Tasks are risk-ordered where it matters: T0 proves the rebuild
mechanism BY HAND before any product code consumes it. The original
DAG was dependency-ordered and proved the riskiest assumption last —
corrected.

### T0: rebuild spike — prove the loop with zero product code
**Depends on:** nothing. **Blocks:** T2, T3, T7 (any task that
consumes the mechanism).
Manual, no product code, no script — four SSH commands:
1. rsync this repo → `amon-sul:/etc/cococoir`, excluding `.git`
   (plain directory flake — see the git-tree trap in Config topology).
2. `nixos-rebuild switch --flake /etc/cococoir#amon-sul` → succeeds
   (inputs fetch over network; first build may be slow).
3. Hand-edit `nixosConfigurations/amon-sul/dashboard.nix`, flip one
   probe value → rebuild again → change live.
4. Rollback via boot menu → old value live.
Proves: the mirror evaluates on-box, the bare-attrset file flows into
the system config, rebuild-as-root works from a box-local flake,
rollback works. Records: first-build fetch needs, what an eval
failure looks like from the box. Decision it owns: e2e scope (in-VM
proves eval-visibility only; full switch stays a manual proof unless
the spike shows an in-VM `switch` is cheap).
**Verification:** all four steps observed on amon-sul; findings
amended into this proposal and carried to docs/STATUS.md at T8.

### T1: `-dashboard-addr` flag + dead-route removal
**Depends on:** none
**Verification:** `cargo test -p cococoir-client` green; default addr
`127.0.0.1:9091` asserted; unknown flags still rejected; demo routes
404.
**Files:** `crates/client/src/app.rs`,
`crates/client/src/dashboard/mod.rs`, `crates/client/src/app.rs` tests
(+ `bacon.toml`/`nix/dev/process-compose.nix` port touch-ups)

### T2: apply runner module + login rate limiter
**Depends on:** T0 (mechanism proven), T1
**Verification:** L0 (mock `CommandRunner`: success/failure/
already-running; journal tail capped; limiter trips and resets).
**Files:** `crates/client/src/dashboard/apply.rs` (new),
`crates/client/src/dashboard/auth.rs`, `crates/client/src/dashboard/mod.rs`

### T3: HTMX apply UI + vendored assets
**Depends on:** T2
**Verification:** L0 route tests (apply flow with mock runner; poll
fragment states); served HTML contains no CDN URLs (daisyUI/htmx
vendored via `include_bytes!`).
**Files:** `crates/client/src/dashboard/components.rs`,
`crates/client/src/dashboard/mod.rs`, `crates/client/src/dashboard/assets/` (new)

### T4: client unit wiring
**Depends on:** T1
**Verification:** L1 eval — unit passes `-dashboard-addr`, sets
`COCOCOIR_CONFIG_PATH` from `networking.hostName`, adds `/etc/cococoir`
to `ReadWritePaths`, systemd tools on `path`.
**Files:** `nix/nixos-modules/client.nix`

### T5: dashboard platform module (vhost + apply unit)
**Depends on:** T4
**Verification:** eval assertions; imported from `cococoir.nix`; vhost
gated on client enable ∧ baseDomain ∧ adminPasswordEnvFile; apply
unit `path` carries `nixos-rebuild` and a flakes-enabled `nix`.
**Files:** `nix/nixos-modules/dashboard.nix` (new),
`nix/nixos-modules/cococoir.nix`, `nix/nixos-modules/client.nix`

### T6: vmtest-wiring tripwires (vmtest + amon-sul eval)
**Depends on:** T5
**Verification:** `nix flake check` green; negative test confirms each
assert fires when its condition is broken.
**Files:** `nix/tests/vmtest-wiring/default.nix`

### T7: box-sync app + amon-sul dashboard.nix extraction
**Depends on:** T0 (formalizes the spike's manual rsync), T5
**Verification:** eval green; app dry-run (repo → box rsync excluding
dashboard.nix, box → repo dashboard.nix pull). rsync excludes `.git`:
`/etc/cococoir` must be a plain directory flake (a git-tracked tree
hides untracked files from eval — the silent-edit trap in "Config
topology").
**Files:** `flake.nix`, `nixosConfigurations/amon-sul.nix`,
`nixosConfigurations/amon-sul/dashboard.nix` (new). Also add
`dashboard.<baseDomain>` to `networking.hosts` (amon-sul.nix:174) so any
on-box component resolving the vhost URL hits local Caddy instead of
hairpinning through the edge — matching the existing jellyfin/auth/
cryptpad/matrix entries.

### T8: e2e wiring + deploy + STATUS proof
**Depends on:** T6, T7
**Verification:** `scripts/vmtest-e2e.sh` PASS with the new dashboard
assertions; manual amon-sul apply gate (see acceptance criteria);
`docs/STATUS.md` updated in the same commit with named proofs; ADR-028
written into PLAN.md.
**Files:** `scripts/vmtest-bootstrap.sh`, `docs/STATUS.md`, `PLAN.md`

### T9: dnsmasq split-horizon (dormant seed for the deferred local-serving arc)
**Depends on:** none (independent of T1–T8; ships after)
**Verification:** L1 eval — `services.dnsmasq` renders with
`address = ["/*.fractal.interdim.net/<lanip>"]` + upstream; L2 —
bootstrap check queries `dig @127.0.0.1 dashboard.<baseDomain>` and
asserts the LAN IP. Honest scope note: no consumer uses it yet (the
box self-resolves via `networking.hosts`; LAN clients need the
deferred router-side DHCP setting), so this is infrastructure seed,
verified by direct query — not a user-facing feature.
**Files:** `nixosConfigurations/amon-sul.nix` only (machine-level,
like the `b263bf1` original — interface name, LAN IP, and upstream
choice are machine facts, not module options; no new toggle per §3)

## Strongest objection

The single admin password is the sole gate between the public internet
and `nixos-rebuild`-as-root — no second factor, no per-identity audit,
and the root client that will one day parse hostile journald bytes is
the same process that can start rebuilds (the rust-rewrite.md §2
warning; the apply unit bounds the *structure* of that risk, not the
capability). If that single password leaks, an attacker can write Nix
that executes as root on the next Apply, with no audit trail tying it
to an identity. Strongest defense: the separation is deliberate and
correct — Dex users never reach the dashboard, only the box owner
holds the admin credential (auth.rs documents "a compromise of Dex
must never grant full control of the system"), so this is not a
shared-secret-across-the-household problem; the vhost tripwire makes
unauthenticated exposure unrepresentable; and the box-DNS seed is
dormant — nothing consumes it and the global vhost carries the
product — so it can never become a single point of failure for the
dashboard. The residual that would change my mind: if the box owner
wants a second factor or a per-identity audit trail, add TOTP for the
admin login as a small, self-contained follow-up — NOT Dex-OIDC, which
would fuse the two identities this design exists to keep apart.
