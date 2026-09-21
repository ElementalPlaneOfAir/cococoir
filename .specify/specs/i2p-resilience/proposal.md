# I2P resilience path — loopback OIDC issuer + box eepsite

Status: proposal (2026-09-16, from discussion with the operator)

## Premise

Remote access today is one live chain: edge box (single Hetzner node
after the ADR-029 pivot) + DNS (proletariat.tech / interdim.net) +
WG. A disruption to any link kills all remote access. The operator
wants a reachability path that (a) survives DNS takedown, (b) survives
edge/ISP filtering, (c) is independent of Hetzner — and wants it as a
feature for the dedicated privacy-focused user segment, not just
insurance.

I2P (eepsite, box-only) is that path. The blocker was auth: OIDC is
origin-bound (single issuer; each app instance trusts one provider).
The solution found in discussion: **dex's issuer becomes a loopback
address** (`http://127.0.0.1:5556/dex`) and every browser-facing URL
is rewritten per access path by Caddy. One dex, one Jellyfin, both
origins, full SSO on each. The issuer refactor is independently
valuable — it makes the box's auth internally self-contained before
I2P exists — so it ships as slice 1; the I2P layer lands on a proven
foundation as slice 2.

Interview answers:

- **Integrates with jellyfin for the time being.** CryptPad is out of
  scope for the I2P path (client-side SPA URL assembly + its own
  `httpUnsafeOrigin` origin model — two independent blockers).
- Two-slice decomposition approved: loopback-issuer refactor first.
- Dashboard instructions document **both** access modes: native I2P
  client as the primary claim, inproxy as the low-friction on-ramp
  *(operator did not explicitly confirm this; flagged — say the word
  and it narrows to native-only)*.
- Zero new customer-facing options. I2P is always-on (constitution 3:
  auto-derive; i2pd is ~50MB). The dashboard is the only surface.
- The client-side URL-assembly worry was checked by the operator:
  Jellyfin's auth is server-rendered ASP.NET — the rewrite seam
  holds. Generalized rule: **I2P-compatibility = server-rendered
  auth surface**; every catalog service gets checked against it at
  module time.

## Acceptance criteria

### Slice 1 — loopback issuer + per-path rewrite vhosts

- [ ] **A1** dex's rendered config has `issuer: "http://127.0.0.1:5556/dex"`;
      dex binds loopback only. Proof: L1 eval + L2 vmtest SSO flow.
- [ ] **A2** A `.i2p` vhost exists per enabled service: plain HTTP,
      Host-routed, no HTTPS redirect, no ACME, and rewrites any
      `Location: http://127.0.0.1:5556/...` to its own scheme+host.
      Proof: L2 `curl -H "Host: auth.<name>.i2p" http://127.0.0.1/…`
      inside the VM returns dex discovery.
- [ ] **A3** The full OIDC login flow completes over the `.i2p` vhost:
      authorize → rewritten to `auth.<name>.i2p` → dex login →
      callback (both callback URLs registered in dex) → token
      exchanged at loopback → Jellyfin session. Proof: L2
      bootstrap.sh check (fails loudly if dex forces `Secure` cookies
      or the plugin rejects the plain-HTTP path).
- [ ] **A4** The clearnet SSO flow (existing vmtest assertions) still
      passes with the loopback issuer + rewrite in place. Proof:
      `vmtest-e2e.sh` PASS unchanged.
- [ ] **A5** L1 tripwires: `vmtest-wiring` asserts the Location rewrite
      renders on every service vhost (both paths) — the silent-drop
      regression class. Proof: `nix flake check` incl. new assertion.

### Slice 2 — I2P layer (gated on slice 1 green)

- [ ] **A6** i2pd runs with a server tunnel → `127.0.0.1:80`;
      destination keys persisted in StateDirectory (stable identity
      across rebuilds). Proof: L2 unit active + keys file exists.
- [ ] **A7** `hosts.txt` rendered from the factory enumeration
      (`jellyfin.<label>.i2p`, `auth.<label>.i2p`,
      `dashboard.<label>.i2p` → the one b32 destination) and served.
      Proof: L2 curl of the file inside the VM.
- [ ] **A8** Dashboard is origin-aware: at the clearnet origin it shows
      the I2P section (b32 destination + QR + native and inproxy
      instructions); at the `.i2p` origin it shows `.i2p` service
      links and marks non-I2P-compatible services (cryptpad)
      "SSO only (clearnet)". Proof: L2 two-Host curls assert both
      renderings.
- [ ] **A9** Live-box proof: from an I2P client (or inproxy), the
      dashboard is reachable and the Jellyfin login flow completes
      over I2P. Proof: named manual test recorded in STATUS.md
      (hermetic vmtest cannot exercise the I2P network itself).

## Smallest version

**Slice 1 alone.** The loopback issuer + rewrite vhosts, both paths
L2-tested, no i2pd anywhere. This ships standalone value: the box's
auth no longer depends on external DNS for its server-side half, and
the `.i2p` vhost sits in the rendered config, hermetically proven,
waiting for a network to arrive on top of it.

Explicitly deferred to slice 2: i2pd, hosts.txt, the dashboard I2P
section, live I2P proof, and everything CryptPad.

Explicitly deferred indefinitely: edge eepsite (the operator decided
I2P is 100% box-only), media over I2P (~100KB/s–1MB/s — the resilience
promise is "reach your data and manage your box", not "stream your
library"), and any local-account fallback beyond the dashboard's
existing password auth.

## Alternatives considered

- **Local accounts on the I2P path (no OIDC over I2P)** — case for:
  zero OIDC risk, works today. Case against: fails the "integrates
  with jellyfin" SSO expectation; a dual account story (SSO on
  clearnet, separate local password on I2P) is exactly the confusion
  a "dedicated users" feature shouldn't ship. Demoted to fallback:
  the dashboard's existing password auth already covers the
  management surface.
- **Second dex instance with a `.i2p` issuer** — case for: no
  rewrite seam. Case against: structurally wrong — each app instance
  trusts exactly one provider, so it buys nothing without a second
  Jellyfin and a second data dir.
- **Loopback issuer + per-path rewrite (winner)** — case for: one
  dex, one app instance, both origins, full SSO on each; server-side
  OIDC moves entirely to loopback (resilience upgrade independent of
  I2P); a known industry pattern (Keycloak's frontend/backend URL
  split). Case against: an unusual issuer value that makes dex
  unfederable off-box; three dex/plugin behaviors must be verified
  (plain-HTTP issuer acceptance, cookie `Secure` flag,
  redirect_uri derivation); the rewrite seam needs tripwires.
- **Tor onion services instead of I2P** — case for: better client
  tooling (Tor Browser needs no inproxy), first-class nixpkgs
  module. Case against: directory-authority dependency, more
  actively filtered in some jurisdictions. Note: the loopback-issuer
  seam is network-agnostic — onion services could ride the same
  rewrite vhosts later. I2P chosen per the operator's product story
  (no directory authorities, censorship-resistant by construction).
- **Do nothing until customers exist (ADR-029 logic)** — case for:
  the ADR-029 pivot cut the HA pair precisely because pre-customer
  reliability investment is a guess. Case against: slice 1 is
  standalone-valuable regardless of I2P, and the operator has named
  the dedicated-user segment as a real target — making this a
  feature, not insurance.

Why the winner wins: it is the only option where one app instance
serves both origins with full SSO, and it upgrades the auth chain's
resilience even if I2P never ships.

## Architecture decisions

New ADR-031 (to land with slice 1 in PLAN.md), covering:

1. **dex issuer is loopback** (`http://127.0.0.1:5556/dex`); browser
   surfaces are per-path Caddy vhosts that rewrite the issuer's
   Location headers. All OIDC RPs must live on the box — that
   contract is what makes the loopback issuer valid. **Revisit
   trigger:** the first off-box OIDC RP re-litigates this design.
2. **The server-rendered seam rule:** the rewrite is valid only where
   every browser-issued URL is server-issued. CryptPad is the
   documented exception.
3. **I2P is box-only, always-on, HTTP-only inside the tunnel** (the
   tunnel's layered encryption is the transport security; standard
   eepsite practice — no TLS, no ACME, no certs on that path).
   Extends ADR-006 (no TLS keys involved at all) and ADR-021 (dex
   remains the sole provider).
4. **I2P name auto-derivation:** `<service>.<first label of
   fortress.baseDomain>.i2p` — same enumeration pattern as ADR-028's
   dnsmasq LAN plane. baseDomain null → fail loud (same failure mode
   as the existing domain default). vmtest derives
   `*.vmtest.i2p` from `baseDomain = "vmtest.local"`.

Constitution cross-check: no new options (3), no separate integration
toggle (4), L1 tripwires for the rewrite seam (7), L2 gate for both
slices (10), ADR + strongest objection recorded (12, 15).

## Tasks

### T1: dex issuer → loopback ✅ (done 2026-09-21)
**Depends on:** none
**Verification:** rendered dex config shows the loopback issuer; dex
unit binds `127.0.0.1:<port>` (already does); L0/L1 green
**Files:** `nix/nixos-modules/services/dex.nix`,
`nix/nixos-modules/integrations/jellyfin-oidc.nix`,
`nix/nixos-modules/integrations/cryptpad-oidc.nix`
*(Amended 2026-09-21 during implementation: cryptpad-oidc also
consumes the dex issuer server-side; the loopback refactor must
update it or clearnet CryptPad SSO — asserted green by A4 — breaks.
CryptPad remains out of scope for the I2P path itself; this is only
its clearnet provider URL.)*

### T2: factory emits `.i2p` vhosts + Location rewrite ✅ (done 2026-09-21)
**Depends on:** T1 (flow only completes with both)
**Verification:** `contract-conformance` L1 still passes;
`vmtest-wiring` asserts the rewrite renders on every service vhost
**Files:** `nix/nixos-modules/services/_contract.nix`,
`nix/nixos-modules/vmtest-wiring` (the L1 check site)

### T3: L2 — both login paths hermetic
**Depends on:** T1, T2
**Verification:** `scripts/vmtest-bootstrap.sh` gains the `.i2p`
Host-header OIDC flow check; `vmtest-e2e.sh` PASS with clearnet SSO
assertions unchanged
**Files:** `scripts/vmtest-bootstrap.sh`,
`nixosConfigurations/vmtest.nix`

### T4: ADR-031 in PLAN.md
**Depends on:** T1–T3 green
**Verification:** `doc-refs` L1
**Files:** `PLAN.md`

### T5 (slice 2): i2pd module + server tunnel
**Depends on:** T4
**Verification:** bootstrap asserts `i2pd` active + destination keys
persisted
**Files:** `nix/nixos-modules/integrations/i2p.nix` (new),
`nix/nixos-modules/default.nix`

### T6 (slice 2): hosts.txt oneshot
**Depends on:** T5
**Verification:** b32 extracted from i2pd keys; hosts.txt rendered
with the factory enumeration; served and curl-able in-VM
**Files:** `nix/nixos-modules/integrations/i2p.nix`

### T7 (slice 2): dashboard I2P section + origin-aware links
**Depends on:** T6
**Verification:** two-Host L2 curls assert clearnet rendering
(destination + QR + instructions) and `.i2p` rendering (links +
cryptpad marker)
**Files:** `crates/client/src/dashboard/mod.rs` (+0–1 sibling files)

### T8 (slice 2): live I2P proof
**Depends on:** T7
**Verification:** named manual test on the deployed box, recorded in
STATUS.md with proof
**Files:** `docs/STATUS.md`

### T9 (blocker, discovered during T3): unblock the L2 gate —
### jellarr pnpm-deps hash mismatch ✅ (done 2026-09-21)
**Depends on:** none
**Verification:** `nix build` of the jellarr closure succeeds
**Files:** TBD by operator decision

*Added 2026-09-21.* The first T3 e2e run failed before reaching the
VM: `jellarr-pnpm-deps` (upstream `venkyr77/jellarr` at the locked
rev `de530bc`) gets a hash mismatch under the nixpkgs the 2026-09-19
flake.lock update pinned (`ec2d622` → `e554fab`, ~3.5 weeks of
nixpkgs): the new toolchain fetches different pnpm content than the
hash upstream hardwires. **Proven pre-existing**: reproduces on clean
HEAD with the i2p-resilience changes stashed. Upstream has no fix
(PR #75 "pin pnpm to 10" was closed unmerged; PR #73 "allow
overriding the jellarr package" is open and would give
`services.jellarr.package`). T3's L2 run is blocked until T9 lands.
Fix options recorded in STATUS.md; operator decides.

## Strongest objection

Slice 2's value only materializes when the primary path is down, and
on that day the user must (a) have pre-configured I2P on their device
and (b) accept the degraded experience. For a residential customer
the probability that both hold is small — the realistic user base
is the operator and a handful of enthusiasts — while slice 1's
rewrite seam permanently adds a debugging surface (three-party
redirect chains, cookie flags, proxy rewrites) to the most fragile
part of the stack: auth. The honest counter, which this proposal
accepts: slice 1 ships regardless (standalone value, hermetic proof),
and slice 2 is cheap enough that serving the named dedicated-user
segment justifies it — but if even slice 1's clearnet SSO proves
brittle under the rewrite, the right call is to stop at T3 and
revisit rather than push a fragile seam into production.
