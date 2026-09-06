# Accounts + device pairing — the self-serve onboarding flow

Status: proposal.

## Premise

Onboarding today is **operator-driven**: a human runs one AdminKey-auth'd
`POST /signup` with the box's WG pubkey and a username, then the box's
`tunnel` section is hand-wired in Nix. There is no email account, no
self-serve pairing, and no customer-facing web surface on the edge. The
ADR-025 "website-signup device token" is still deferred, so a
re-provisioned box always needs a human.

We're building the v3 control-plane customer layer: **an email account
owns many devices**, each device is a home-server box with its own route +
subdomain, and a new box self-pairs by showing a code the owner claims on
the website. Email verification (magic link) is in scope — the user
confirmed an SMTP/sending capability is expected, and billing emails are
a near-term need. Fractal's records are explicitly expendable: no
migration burden.

If we don't build it: every new customer is an operator touch, remote
access never self-heals on a fresh box, and the "charge for services"
path has no account to bill.

## Flow (end to end)

```
NEW BOX                     EDGE (interdim.net)                 OWNER
────────                    ───────────────────                 ─────
boots unpaired
dashboard: "Pair this
device" → shows 5-word code
    │
    ├─ POST /api/pair ─────────► create PendingPairing {code,
    │   {pairing_code,              pubkey, device_name}
    │    public_key}               status=waiting, TTL 30min
    │
    │                            (owner signs up: email + username
    │                             + password → magic link → active)
    │
    │  GET /api/pair/:code ◄───────────────┐
    │   (poll, waiting)                    │  POST /api/pair/:code/claim
    │                                      │   {code} (session-auth)
    │                                      ├─ allocate /128 + WG tunnel
    │                                      ├─ create Device under account
    │                                      ├─ wire WG peer + forwards +
    │                                      │   DNS {dev}.{user}.interdim.net
    │                                      ├─ generate device_token
    │                                      └─ mark pairing claimed
    │
    ├─ GET /api/pair/:code ────► 200: claimed + {tunnel config,
    │   → claimed                    device_token, hostname}
    ├─ write /var/lib/cococoir/tunnel.json + device-token
    ├─ bring up wg0, forwarder binds
    └─ dashboard: "Paired — main.alice.interdim.net"
```

Reboot: the box reads its persisted tunnel state and brings wg0 up with
no user action. Re-key (re-provision): the box calls
`POST /api/device/register` with its `device_token` + new pubkey → peer
rotated on the SAME route (no human, no AdminKey) — this is the gap
ADR-025's "device token" was always meant to close.

## The pairing code (decision: 5 words, not characters, not QR)

The code is **5 lowercase English words from a fixed wordlist**, joined
by hyphens (e.g. `brass-honey-velvet-amber-dune`). Rationale: the owner
types it on the website (there is no QR to scan and no URL to copy), and
short, distinct words are far easier to type and to read back aloud than
a random character string. The wordlist is a fixed, curated subset
(~4k–8k short, unambiguous, non-confusable words); claim input is
normalized (lowercase, separator-insensitive) before lookup, so
`Brass honey velvet amber dune` and `brass-honey-velvet-amber-dune` both
claim the same pairing. Entropy: ~12 bits/word × 5 ≈ 60 bits — ample
against guessing given the 30-minute TTL + per-code single-use.

## Acceptance criteria

- [ ] **L0** Account lifecycle: signup → `pending` → magic-link verify →
      `active`; login issues a session cookie; logout invalidates it.
      Passwords are bcrypt-hashed, never plaintext; a second signup with
      the same email is rejected; the verify token is single-use + expires.
      Maps to T2, T3.
- [ ] **L0** Password reset: a logged-out user can request a reset email
      (magic link, single-use + expiring like verify); the reset link
      replaces the password without a session; an unknown email is
      indistinguishable from a known one (no account enumeration). Maps
      to T2, T3.
- [ ] **L0** Account deletion unwires, never wipes: `DELETE /api/account`
      removes the account's WG peers + forwards + per-device DNS + device
      tokens + sessions; the box's local data is untouched (it just loses
      remote access and can re-pair). Maps to T8.
- [ ] **L0** Pairing lifecycle: `POST /api/pair` creates a waiting
      `PendingPairing`; a session-auth'd claim allocates a fresh `/128` +
      WG tunnel + per-device DNS under the account, wires the live WG peer
      + forwards, and flips status to `claimed`; the box's poll then
      receives the tunnel config + `device_token`; a claimed/expired code
      is rejected (single-use). Maps to T5.
- [ ] **L0** The pairing code is 5 words from the fixed wordlist and
      claim input is normalized (case + separator-insensitive); the box's
      persisted code survives a restart (same code re-shown); a collision
      on begin regenerates. Maps to T5, T7.
- [ ] **L0** `device_token` authorizes re-registration (pubkey rotation)
      without AdminKey; rotation keeps the route; an invalid token 401s.
      Maps to T5.
- [ ] **L0** Email is behind a `Mailer` trait: `SmtpMailer` (lettre,
      STARTTLS + AUTH) and a `MockMailer` that asserts the message
      (recipient, magic link with the token) in tests. Maps to T1.
- [ ] **L0** `POST /signup` (AdminKey) keeps working with the same JSON
      wire shape + hostname (`{username}.{domain}`), now served at
      `/api/wireguard/new` — it creates an owner-less device on the
      unified model, so the existing `edge-forward` L2 test and the
      operator path do not break. Maps to T4.
- [ ] **L1** `nix flake check` green: SMTP secrets added to
      `secretspec.toml`, `vmtest-wiring` unchanged, `edge-forward`
      passes. Maps to T1, T4.
- [ ] **L2** The single-VM edge+client vmtest runs the onboarding flow
      end to end: in-VM edge + client, client posts its pairing code,
      the test claims it, the tunnel comes up, and `curl
      https://{device}.{user}.interdim.net` through the `/128` returns
      200. This is the "serving infrastructure is hammered down" gate.
      Maps to T11.
- [ ] Per-device DNS naming: `{device}.{username}.{domain}` + wildcard;
      the reconcile loop enumerates devices (not usernames). Maps to T8.

## Smallest version

A vertical slice that works for a real second person: an email + username
+ password signup verified by a magic link (SMTP configurable; a
console/dev mailer prints the link when SMTP secrets are absent), a new
box that shows a 5-word pairing code and polls until claimed, a website
where the owner claims the code, and the box coming up on its tunnel.
`POST /signup` (AdminKey) stays as the operator path. No QR, no billing,
no account-level DNS records.

## Alternatives considered

- **Keep one-customer-per-box (account = box)** — case for: no data-model
  change. Case against: the user chose "one account, many devices"; the
  per-device subdomain model is where "pair a NEW device" has room to
  grow. Rejected by decision.
- **Email is login id only, no verification** — case for: no SMTP
  dependency, fastest. Case against: the user chose magic-link
  verification, and billing (a stated goal) needs a reachable, owned
  email anyway. Rejected by decision.
- **Web issues the code, box consumes it** — case for: the web controls
  code entropy + expiry centrally. Case against: the box must be online
  to show a code, and the user chose box-shows-code ("I showed the user
  <pairing id>"). The box-generated code also makes begin idempotent and
  displayable before the first dial-out. Rejected by decision.
- **Server generates the pairing id** — case for: central entropy,
  guaranteed uniqueness. Case against: the box can't render a code until
  it reaches the edge; box-generated ids with a SETNX-on-begin collision
  guard are just as unique. Rejected.
- **QR code in the smallest version** — case for: zero typing on mobile.
  Case against: the user chose code-only; a QR needs a QR library + a
  scannable render and the code is typed once, for 30 minutes. Deferred
  out of scope (can be added later without touching the flow).
- **Random character string code (e.g. 10× base32)** — case for: compact,
  simple entropy. Case against: the user chose 5 words — distinct words
  are readable-aloud and far less error-prone to type than a character
  soup when you can't copy the URL. Wordlist entropy (~60 bits) still
  dwarfs the 30-minute TTL + single-use window. Rejected by decision.
- **Self-hosted MTA (postfix/exim) on the edge** — case for: no external
  provider, "an SMTP server" literally. Case against: outbound
  deliverability from a fresh Hetzner IP is the project's most likely
  silent failure (spam-folder / 550s), and an MTA is a big moving part
  on a box that runs one Rust binary. **Decision: off-the-shelf
  transactional provider** (Resend/Postmark/SendGrid-class) via SMTP
  relay — deliverability and reputation are the provider's problem, not
  ours. The `Mailer` interface keeps the relay a secrets-config choice;
  the specific provider is a provisioning decision (the `edge.env`
  SMTP_* secrets), not a code decision. SPF/DKIM records still get added
  in DNS (we own the zone).
- **Build the flow on the current control plane unchanged (keep
  `Customer`)** — case for: smaller diff. Case against: two competing
  identity models (customer vs account+device) is exactly the "second
  source of truth" debt this project bans. Unify: `Customer` → `Device`
  with an `owner` field; the AdminKey `/signup` creates an owner-less
  device with a backward-compatible hostname.

Why the winner wins: box-generated 5-word code is the flow the user
described verbatim and the code they chose to type; account→devices is
the model billing and multi-box growth build on; the `Mailer` trait keeps
SMTP honest (provider swappable by secret, mockable tests); unifying on
`Device` avoids a parallel identity store.

## Architecture decisions

- **New ADR-028 (advances ADR-025's v3 shape):** the control plane moves
  from one-`Customer`-per-box to **Account → Devices**. An account is
  keyed by email (login) and owns a DNS-safe username (the subdomain
  root) + any number of devices. A device is a home-server box with its
  own `/128`, WG tunnel address, pubkey, and hostname
  `{device}.{username}.{domain}`. Redis stays the store (ADR-025).
- **Pairing protocol (box-shows-code).** The box generates a **5-word
  code** from the fixed wordlist (lowercase, hyphen-joined, ~60 bits) and
  shows it; claim input is normalized (case + separator-insensitive).
  `POST /api/pair` registers it as `waiting` (SETNX guards a collision);
  `POST /api/pair/:code/claim` (session-auth) allocates the route,
  creates the device, and flips the code to `claimed`. `GET
  /api/pair/:code` returns status; on `claimed` it returns the tunnel
  config + `device_token` so the box can finish. Codes are single-use,
  TTL ~30min. No QR.
- **Device token (closes ADR-025's deferred gap).** Pairing returns a
  long-lived `device_token` the box persists; `POST /api/device/register`
  accepts it (instead of AdminKey) to rotate the box's pubkey on the
  same route. Stored hashed (SHA-256), same discipline as `AdminKey`.
- **Sessions live in Redis** (`cococoir:session:{token}` → account,
  TTL 7d, 32-byte random token, HttpOnly + SameSite=Lax cookie). CSRF is
  mitigated by SameSite=Lax for now; flagged as hardening, not shipped.
- **Email via a `Mailer` trait to an off-the-shelf transactional
  provider.** `SmtpMailer` (lettre, STARTTLS + AUTH) pointed at the
  provider's SMTP relay (SMTP_HOST/PORT/USER/PASS/MAIL_FROM in the edge's
  `secretspec.toml` / `edge.env`). IP-reputation and deliverability are
  the provider's problem, not ours (user decision). A dev/console mailer
  prints the magic link when SMTP secrets are absent so the L2 test and
  local runs don't need a relay. Magic link =
  `https://{domain}/verify?token=<32-byte random>`, single-use, 24h TTL.
  **The interface is the self-host seam (user requirement):** `Mailer`
  is just SMTP submission (RFC 6409, port 587, STARTTLS + AUTH), which
  is the same wire contract a future self-hosted MTA (postfix/exim)
  presents — so "self-host later" is a secrets change
  (SMTP_HOST/PORT/USER/PASS), not an interface change. Provider choice
  stays a provisioning decision; `MAIL_FROM` and magic links derive from
  the injected `root_domain`, never a hardcoded domain (so the planned
  domain migration is config, not code).
- **DNS moves to per-device.** New `upsert_device`/`remove_device` naming
  (`{device}.{username}.{domain}` + wildcard) alongside the existing
  per-username `upsert_customer`; the reconcile loop enumerates devices.
  Account apex records (`{username}.{domain}`) are dropped.
- **Allocation is shared.** The current `signup` core is refactored into
  `allocate_device(owner, device_name, public_key, ...)`; both the
  AdminKey `/signup` path and the pairing claim call it. One route +
  forward + DNS code path (the DRY move; also fixes the redundant paths).
- **Operator path survives.** `POST /signup` (AdminKey) stays, creating
  an owner-less device whose hostname is `{username}.{domain}` (wire
  shape unchanged) so the `edge-forward` L2 test and operator flow keep
  working. Pairing is the customer path.
- **API namespace: all API under `/api/`, web at root (plan amendment,
  2026-09-06, born from the T3 `/signup` collision, then refined to a
  resource-grouped surface 2026-09-06).** The web signup page needed
  `GET /signup`; poem's `Route` matches path-first and returns 405 on
  method mismatch with no fallthrough, so a GET page and a POST API
  cannot share a path. Resolution: exclusive namespaces.
  - **One API service, ONE swagger doc.** The whole API is ONE
    poem-openapi service — users + wireguard + health merged — mounted
    under `/api/`, with the swagger UI at `/api/docs` and the spec at
    `/api/openapi.json` (`.server("/api")` so try-it-out resolves).
    This is deliberate: two poem-openapi services cannot coexist in one
    route tree (each registers an internal `/*--poem-rest` catch-all
    that collides), so health is NOT a separate service — it lives at
    `/api/healthz` `/api/readyz` `/api/status` with everything else.
    The web UI at the root (`/`, `/register`, `/login`, `/verify`,
    `/reset`, `/auth/*`) is server-rendered forms over the same
    `ControlPlane` account methods.
  - **Grouped by resource:**
    - `/api/users/{register,login,verify,reset_password,reset_password/confirm}`
      — public account lifecycle (session token IS the auth).
    - `/api/wireguard/{new, pubkey}` + collection `/api/wireguard`
      (list, AdminKey) and `/api/wireguard/:username` (delete,
      AdminKey). The operator provisioning path is `POST
      /api/wireguard/new` (was `POST /signup`); T5 pairing lives at
      `/api/pair*` and T7 at `/api/device/register`, all under `/api/`.
  - **T4's "same wire shape"** now means "same JSON request/response at
    `/api/wireguard/new`"; the `edge-forward` L2 test, the provision
    script echo, and the mod.rs spec-gate tests moved with it. The web
    signup page lives at `/register` (not `/signup`).
- **Billing is out of scope** but the account record carries a
  `status`/`plan` field so Stripe can attach later (PLAN v3). Flagged,
  not built.
- **Password reset ships in this arc.** Same mechanism as verify (magic
  link via the `Mailer`, single-use, 24h TTL) — one "email a token"
  primitive powers both activation and reset. Reset works logged-out and
  does not require a session; unknown emails get the same response as
  known ones (no account enumeration).
- **Account deletion unwires, never wipes.** `DELETE /api/account`
  (session-auth) removes every device's WG peer + forwards + per-device
  DNS + device tokens + sessions. The box's local data is the box's —
  it is not touched; the box simply loses remote access (its tunnel
  dies, its `device_token` is revoked) and can be re-paired under a new
  account. This matches the "remote access is the product; the box's
  data is the customer's" line.

## Tasks

### T1: Mailer (SmtpMailer + MockMailer) + SMTP secrets
**Depends on:** none
**Verification:** `cargo test -p cococoir-controlplane` green; MockMailer
asserts recipient + magic-link token; SmtpMailer builds a lettre message
with STARTTLS+AUTH; `secretspec.toml` declares SMTP_* (optional =
dev-mailer fallback) and the secret contract test updated. L0.
**Files:** `crates/controlplane/src/controlplane/mail.rs`,
`crates/controlplane/Cargo.toml`, `crates/controlplane/secretspec.toml`

### T2: Account model + sessions + auth + reset API (Redis)
**Depends on:** T1
**Verification:** L0 tests for signup→pending→verify→active, duplicate
email rejection, bcrypt hashing (never plaintext), login/logout session
round-trip, single-use expiring verify token, password reset (request →
token email → reset without session, no account enumeration). Pure logic
testable without the boot globals (inject Redis + mailer).
**Files:** `crates/controlplane/src/controlplane/account.rs`,
`crates/controlplane/src/controlplane/mod.rs`

### T3: Web UI skeleton — landing, signup, login, verify, reset
**Depends on:** T2
**Verification:** `cargo test` (poem TestClient) asserts the pages render
and the forms drive the T2 API (signup → mail mock gets the link → verify
link activates → login sets the cookie; reset request → mail mock → reset
link sets a new password). momenta + daisyUI, same as the client
dashboard.
**Files:** `crates/controlplane/src/controlplane/web.rs`,
`crates/controlplane/Cargo.toml`

### T4: Device model + shared allocation + operator /signup compat
**Depends on:** T2
**Verification:** `edge-forward` L2 still passes (AdminKey `/signup`
creates an owner-less device at `/api/wireguard/new`, same hostname shape);
new L0 tests for `allocate_device` (route + forward + DNS), list/delete
over devices; `Customer`→`Device` rename with `owner: Option<String>`.
**Files:** `crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/dns.rs`,
`nix/tests/edge/default.nix`

### T5: Pairing lifecycle API (5-word codes) + device token + rotate
**Depends on:** T4
**Verification:** L0 round-trip: begin → status waiting → claim → status
claimed with tunnel config + device_token → re-claim/expired rejected;
the 5-word code is generated from the wordlist, claim input normalizes
(case + separators), a collision on begin regenerates;
`POST /api/device/register` with a device_token rotates the pubkey on the
same route without AdminKey; bad token 401s.
**Files:** `crates/controlplane/src/controlplane/pairing.rs`,
`crates/controlplane/src/controlplane/mod.rs`

### T6: Web UI — devices page + add-device (claim), code-only
**Depends on:** T5
**Verification:** `cargo test` asserts the logged-in devices page lists
devices, the add-device form claims a code (success + wrong-code error),
and the claim page normalizes typed input (case/separator-insensitive).
No QR.
**Files:** `crates/controlplane/src/controlplane/web.rs`

### T7: Client pairing module (box side)
**Depends on:** T5
**Verification:** `cargo test -p cococoir-client` green: the dashboard
`/pair` screen generates + persists a 5-word code (idempotent across
restarts), posts `POST /api/pair`, polls until claimed, then writes
`/var/lib/cococoir/tunnel.json` + `device-token` (0600), brings up wg0,
and reloads the forwarder; boot prefers persisted tunnel state over the
Nix `tunnel` section. Mock the edge API (no live network in L0).
**Files:** `crates/client/src/pairing.rs`,
`crates/client/src/app.rs`, `crates/client/src/tunnel.rs`

### T8: Account deletion (unwire, never wipe)
**Depends on:** T5
**Verification:** L0: `DELETE /api/account` removes every device's WG
peer + forwards + per-device DNS + device tokens + sessions in one pass;
a re-`GET /api/me` is 404; the underlying box data is untouched (only the
tunnel/remote-access wiring is gone). Web UI: account page has a
delete-with-confirmation button.
**Files:** `crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/web.rs`

### T9: Per-device DNS naming + reconcile over devices
**Depends on:** T4
**Verification:** L0 tests for `upsert_device` (`{device}.{user}.{domain}`
+ wildcard) and `reconcile_pass` enumerating devices; the account-apex
records are no longer created.
**Files:** `crates/controlplane/src/controlplane/dns.rs`

### T10: Single-VM edge+client wiring in vmtest (foundation)
**Depends on:** none
**Verification:** `nix flake check` green; `vmtest.nix` enables the real
`services.cococoir-client` module + an in-VM edge unit (mirror the
`nix/tests/edge/` edge node: Redis, wg0, secrets env, admin key =
sha256("test-admin-key")); client forwards `10.10.0.x:80/443 →
127.0.0.1:80/443`; a `/signup` inside the VM allocates + forwards to the
client. This is the base the onboarding e2e (T11) builds on — added from
converge: STATUS "Next move 7" planned it but it is not yet in
`vmtest.nix`.
**Files:** `nixosConfigurations/vmtest.nix`, `nix/tests/default.nix`,
`scripts/vmtest-bootstrap.sh`

### T11: L2 — single-VM edge+client onboarding e2e + SMTP + SPF/DKIM
**Depends on:** T1–T10
**Verification:** `scripts/vmtest-e2e.sh` green on vermissian: in-VM edge
+ client run the full flow (signup via console mailer, pair, claim, wg0
up, `curl https://{device}.{user}.interdim.net` through the `/128` → 200),
new assertions in `vmtest-bootstrap.sh`; `edge.nix` gains the SMTP relay
env + DNS TXT records for SPF/DKIM.
**Files:** `nix/tests/default.nix`, `scripts/vmtest-bootstrap.sh`,
`remote-infra/system-manager/edge.nix`, `remote-infra/tofu/dns.tf`

## Strongest objection

Two of this arc's three new trust anchors are precisely the silent-failure
seam class this project bans, and neither has a tripwire that exists yet.
First, **email verification is gated on outbound SMTP deliverability** —
a magic link that lands in spam or gets 550'd means a signup that
"worked" (account `pending`, mail sent) with the customer never able to
activate, and nothing in the current test stack exercises a real relay.
Second, **the pairing code is a bearer credential with a claim race**: a
box's code is high-entropy but short-TTL, and whoever claims first owns
the box — a watcher who sees or overhears a code could hijack an
unclaimed box before its owner. The box trusts its claimant, so there is
no second factor. Defense: this is the same trust model every physical
pairing code uses (HomePod/Sonos/Nest) — the code is shown on a screen
the owner is standing in front of — and the entropy
+ TTL + single-use bounds the race to a ~30-minute window with an
actively-observed box; email deliverability is mitigated by SPF/DKIM in
the zone we own and the relay being a swappable secret, with the
`MockMailer` + L2 console-mailer path keeping the flow testable without a
relay. The residual risk is that a real relay's behavior is only proven
by the first real signup — that first signup should be the demo's, not a
paying customer's.
## Converge results — 2026-09-05 (pre-implementation base check)

Diagnostic only; no code changed. Ground truth refreshed before the arc.

### Verified green (the base is solid)
- `bash scripts/status.sh` — 3/3 L1 checks PASS.
- `cargo test --workspace` — 151 tests, 0 failures (controlplane 64,
  client 39, core 48).
- `nix flake check` — all checks passed, including the `edge-forward`
  L2 VM test (the AdminKey `/signup` path T4 must keep alive).

### Drift detected
- **T10 foundation missing.** `vmtest.nix` does NOT enable
  `services.cococoir-client` and has no in-VM edge unit — STATUS "Next
  move 7" planned it but it never landed. The onboarding e2e (T11)
  depends on it. Added as T10.
- **amon-sul is gone.** `nixosConfigurations/amon-sul.nix` + custom/
  deleted and `amonSul` removed from `flake.nix` (matches "nuke
  fractal"). STATUS entries for amon-sul (matrix-synapse, jellarr
  bootstrap, admin env wiring, migration) are moot and should be pruned.
- **The pairing-code type changed mid-flight** (chars → 5 words, no QR)
  after the first write; the flow diagram, AC, alternatives, and T5–T7
  were updated to match. No residue found (grep verified).
