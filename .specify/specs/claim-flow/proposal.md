# Claim flow — dormant invites, word codes, dashboard enrollment

## Premise

**Why this, why now.** Remote access is the product's core value prop and
the path to it is broken for the exact customer the business plan names.
Lived evidence (2026-09-26): the operator logged into the deployed
proletariat.tech, could generate invites, and sat in front of a fresh box's
local dashboard (`local_ip:3000`) with **no bridge between the two**. The
docs already promise the bridge (`getting-started.md`: "the welcome flow on
the box and the dashboard's machines page walk you through naming it and
claiming it") — the box-side welcome flow does not exist. The only
enrollment path is hand-editing `/etc/fortress-client.json` before boot.

Three concrete defects, all confirmed in code:

1. **No claim surface.** `crates/client/src/dashboard/` has zero
   invite/enroll/remote-access UI; `pairing::enroll` runs only from a
   config-file `invite` block at boot (`app.rs:108`).
2. **Boot-order dead end.** A fresh self-enrolled box whose forwards use
   `{tunnel_ip}` exits before the dashboard serves (`app.rs:166-175`), so
   even the config editor is unreachable on the box that needs claiming.
3. **Invite lifecycle lies.** `InviteStatus::Waiting` is set at creation
   (`pairing.rs` `invite_create`); the machines page stamps a fresh invite
   "waiting" and renders "Name this machine" + Approve before any machine
   dialed (`web.rs:409-435`). Approve on a dormant invite then fails with
   "invite is not waiting" — the UI invited the action and the error
   contradicts the UI. Owner-visible state must be `dormant` (created, not
   used) vs `waiting` (machine dialed via `begin`, awaiting approval).

**Cost of not building it.** Non-technical customers cannot claim a box at
all; the self-serve tier and the docs' claim flow remain fiction. The
operator's own machine stays unclaimed.

**Smallest version a real customer feels.** Open the box's dashboard on the
LAN, paste the invite URL generated on their account page, approve + name
the machine on the site, and see remote access light up — no terminal, no
JSON, no Nix.

**First acceptance criterion cut if forced:** word-code ergonomics (the
10-char code could survive one release; the claim seam and honest states
cannot).

## Acceptance criteria

- [ ] **L0 — invite lifecycle honesty:** `invite_create` yields `dormant`
  (no approve form, revoke only); `invite_begin` moves it to `waiting`;
  `invite_approve` on a `dormant` invite is rejected at the control-plane
  layer with a distinguishable error; deny/revoke semantics per state.
  Tripwire test for the reported bug (approve-before-begin) in the same
  commit. (`cargo test -p fortress-controlplane`)
- [ ] **L0 — machines surface tells the truth:** dormant invites render
  their share URL persistently + "waiting for a machine to use this" +
  Revoke; `waiting` invites render the candidate pubkey + Name/Approve +
  Deny/Revoke. Named test asserting no approve form for a dormant invite.
- [ ] **L0 — word codes:** invite codes are 4 hyphen-joined lowercase words
  from an embedded ≥16k-word list (target 40k common English words);
  validation accepts them case-insensitively and rejects off-list words;
  entropy floor asserted (words × log2(list) ≥ 50 bits). Codes round-trip
  through `/i/{words}` URL shape and the `fortress:invite:{code}` keys.
  (`cargo test --workspace`)
- [ ] **L0 — paste-only enrollment wire:** the box can build a complete
  tunnel config from an invite URL alone — the edge serves its WG endpoint,
  allowed-ips and public key from one info endpoint (extended
  `/api/wireguard/pubkey` response); `InviteConfig` slims to the URL (+ tun
  defaults); `enroll()` fetches edge facts instead of reading them from
  config.
- [ ] **L0 — claimable degraded mode:** boot with no tunnel state +
  `{tunnel_ip}` forwards serves the dashboard and health instead of
  exiting; a claim (begin → approved → persist) brings the tunnel up with
  no human action afterward (re-exec into full mode). Test against the
  existing mock `EdgeClient`.
- [ ] **L0 — claim form:** the dashboard's "Remote access" surface shows
  claim state (not claimed / awaiting approval / claimed with
  `{name}.{domain}`) and accepts an invite URL. (`cargo test -p
  fortress-client`)
- [ ] **L1 — composition intact:** `nix flake check` green, including
  `vmtest-wiring` with an added assertion if the client module's wiring
  changes.
- [ ] **L2 — onboarding e2e** (folds into pending accounts-and-pairing
  T11): fresh boot → claim via the dashboard form → approve + name on the
  machines page → `curl https://{machine}.{domain}` through the tunnel.
  Gate before claiming "works".

## Smallest version

Ships first: honest invite states (defect 3) and word codes — both are
backend/site-scale and independently shippable, and the state fix unblocks
the operator's confusion today. Then: claimable boot mode + claim form +
edge info endpoint (the claim seam). Deferred explicitly: did-you-mean
suggestions for mistyped words, QR-code transfer, a CLI claim wrapper,
machine rename/remove surfaces, and rebind-without-restart (see strongest
objection).

## Alternatives considered

- **A. Paste invite URL into the box's dashboard (winner).** For: reuses
  `pairing::enroll` and the begin/poll wire verbatim; zero new API for the
  pairing itself; works on any box with a browser; the dashboard is already
  the customer's config surface. Against: user copies a URL between two
  devices (mitigated by word codes for manual typing).
- **B. Box displays a pairing code typed into the site (TV / `gh auth`
  style).** For: best typing ergonomics, no URL transfer. Against: new
  device-code grant API + site UI; diverges from the decided invite-URL
  model (accounts-and-pairing chose URLs over box-displayed codes because
  the invite travels out-of-band and a leaked code only produces a visible
  pending request); more surface than the problem needs now.
- **C. SSH one-liner (`fortress-claim <url>`).** For: trivial, headless.
  Against: SSH is exactly what the target customer won't do. Acceptable
  later as a thin wrapper, not as the flow.
- **D. Docs-only ("edit this JSON").** For: zero code. Against: keeps the
  dead end; docs already promise a claim flow that doesn't exist.
- **Split into three proposals** (states / codes / claim UI). For: the
  first two ship in hours. Against: one customer journey, one review; the
  task DAG below orders the shippable increments first anyway.
- **Word codes: 5 words from a curated ~7.7k diceware list instead of 4
  from 40k.** For: lists exist and are pre-curated for spelling; same
  entropy. Against: 4 words is a shorter URL and less typing; the user
  explicitly wants common English words. Winner: 4 words from a frequency
  list, filtered for typeability (ASCII, no proper nouns, no profanity,
  4–9 letters); if filtering lands under 16k words, generate 5 words
  instead — one rule: ≥50 bits total.

## Architecture decisions

No new ADR. Amends `.specify/specs/accounts-and-pairing/proposal.md`:
its "10-char URL code" decision becomes **4-word URL code** (`/i/{words}`
instead of `/a/{code}` — clean cut, no dual-format support; live invites
die at deploy and are regenerated, 30d TTL). Its lifecycle gains the
explicit `dormant` state the design always assumed ("owner sees 'this
machine is trying to join'" presupposes a machine dialed). Boot-order
decision: **claim persists then re-execs the process** (argv exec, same
PID) into full mode — one boot path owns tunnel bring-up; no systemd
Restart dependency, works in dev runs too.

## Tasks

### T1: InviteStatus::dormant + honest transitions — DONE 2026-09-28
**Proof:** `cargo test --workspace` 241/241 with `REDIS_URL` (valkey);
tripwires ran: `approve_or_deny_before_begin_is_rejected`,
`revoke_drops_dormant_and_waiting_invites`, web-ui
`dormant_invite_offers_revoke_but_never_an_approve_form`.
**Depends on:** none
**Verification:** `cargo test -p fortress-controlplane` + `cargo test -p
fortress-web-ui` — new tests: create⇒dormant, begin(dormant)⇒waiting,
approve(dormant) rejected with a distinguishable error (the reported-bug
tripwire), revoke from dormant/waiting, approve remains one-shot.
`cargo test --workspace` green.
**Files:** `crates/controlplane/src/controlplane/pairing.rs` (+ in-file
tests; `InviteError::NotBegun`), `crates/controlplane/src/controlplane/web.rs`
(mapping arm only)
**Amendment 2026-09-28:** the tree carried in-flight
`site-machines-dashboard` work (accepted as baseline): the machines
markup now lives in `crates/web-ui/src/lib.rs` (shared poem+site
component) with its OWN display `InviteStatus` (incl. `Dormant` +
approve-gating tests) and `api.rs` maps `NotBegun`. The domain enum +
transitions are this task; the display half already exists there.

### T2: Word invite codes
**Depends on:** T1 (same file)
**Verification:** `cargo test --workspace` — code shape
(`^[a-z]+(-[a-z]+){3}$`), case-insensitive accept/normalize, off-list word
rejected, entropy-floor assertion (list size × 4 words ≥ 50 bits),
collision retry still terminates. Fixtures updated to word codes
(site `lib.rs`/`api.rs` tests use 10-char codes today).
**Files:** `crates/controlplane/src/words.txt` (new),
`crates/controlplane/src/controlplane/pairing.rs`

### T3: Machines surface renders states; `/i/{words}` URLs
**Depends on:** T1, T2
**Verification:** named tests: share URL persistently visible on dormant
(still `fresh`-gated in the shared markup); join page + invite URLs use
`/i/{words}`. `cargo test --workspace` green.
**Files:** `crates/web-ui/src/lib.rs` (share-URL gating + URL shape),
`crates/controlplane/src/controlplane/web.rs` (join route/copy),
`crates/site/content/docs/getting-started.md`
**Amendment 2026-09-28:** state rendering (dormant/waiting gating) landed
with T1's sibling work in `crates/web-ui/src/lib.rs`; T3 keeps only the
share-URL persistence + `/i/` shape. `crates/site/src/pages/auth.rs`
join page still moves here if the site surface keeps one.

### T4: Edge tunnel-info endpoint; InviteConfig slimmed to URL
**Depends on:** none (parallel with T1–T3)
**Verification:** `cargo test --workspace` — info response carries
`publicKey`, `endpoint`, `allowedIps`; `enroll()` builds `TunnelConfig`
from fetched facts; `InviteConfig` (URL only) parses and enrolls against
the mock `EdgeClient`; Nix-wired static `tunnel` path unchanged.
**Files:** `crates/controlplane/src/controlplane/mod.rs`,
`crates/site/src/api.rs`, `crates/client/src/pairing.rs`

### T5: Claimable degraded boot mode
**Depends on:** T4
**Verification:** `cargo test -p fortress-client` — boot with no tunnel
state + `{tunnel_ip}` forwards does not exit; dashboard+health serve;
enroll persists then triggers re-exec; full boot resolves from
`tunnel.json` (existing tests keep passing). L1: `nix flake check` green
with `vmtest-wiring` assertion added if module wiring changes.
**Files:** `crates/client/src/app.rs`, `crates/client/src/pairing.rs`

### T6: Dashboard claim surface
**Depends on:** T5
**Verification:** `cargo test -p fortress-client` — claim form posts an
invite URL, status surfaces (not claimed / awaiting approval / claimed with
`{name}.{domain}`) driven by the shared enroll state; admin auth still
gates it. Then the L2 leg: T7.
**Files:** `crates/client/src/dashboard/mod.rs`,
`crates/client/src/dashboard/components.rs`

### T7: Onboarding e2e + STATUS
**Depends on:** T1–T6
**Verification:** `scripts/vmtest-e2e.sh` (accounts-and-pairing T11 shape:
invite → claim via dashboard form → approve+name on `/machines` → curl
through the `/128`); `docs/STATUS.md` updated in the same commit with the
proof named.
**Files:** `scripts/vmtest-e2e.sh` (or `vmtest-bootstrap.sh`),
`docs/STATUS.md`

## Strongest objection

**The re-exec lifecycle is a shortcut around the runtime-rebind machinery
the architecture already knows it needs.** ADR-025 demands a forwarder that
adds/removes forwards in memory (no restart drops tunnels); claim-with-re-exec
introduces a second, coarser lifecycle (whole-process restart on state change)
that must be undone when client-side rebind lands — textbook weight on the
airplane, shipped in the most sensitive seam (boot) of the L4 path that is
currently the proven core. The version that is *right* is a forwarder that
simply starts forwarding when `tunnel.json` appears. Counterargument, for the
record: re-exec is ~10 lines reusing one boot path vs. new L4 lifecycle code
we would have to invent under-tested; claim happens exactly once on an idle
box; and rebind is edge-side work regardless (different process). But if the
re-exec proves fiddly in testing (socket/fd semantics, dev runs, systemd),
do not paper over it — stop and build the watch-channel version, and treat
that expansion as a proposal amendment.
