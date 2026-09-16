# Accounts + device pairing — the self-serve onboarding flow

Status: proposal — **amended 2026-09-16** (account = UUID + email, no
username; flat `{machine}.proletariat.tech` hostnames; enrollment via
owner-generated invite URLs with an approve/deny gate, replacing the
box-shows-5-word-code flow). T1–T3 landed under the pre-amendment
design; the account work they landed (username field, subdomain root)
is superseded by T4 of this amendment — Fractal-era records are
expendable, accounts re-register.

## Premise

Onboarding today is **operator-driven**: a human runs one AdminKey-auth'd
`POST /signup` with the box's WG pubkey and a username, then the box's
`tunnel` section is hand-wired in Nix. There is no email account, no
self-serve pairing, and no customer-facing web surface on the edge. The
ADR-025 "website-signup device token" is still deferred, so a
re-provisioned box always needs a human.

We're building the v3 control-plane customer layer: **an account owns
many machines**, each machine is a home-server box with its own route +
subdomain, and a new machine self-enrolls via an **owner-generated
invite URL** (`proletariat.tech/a/<code>`): the machine (possibly
shipped preinstalled) dials the invite, the owner sees "This machine is
trying to join your network" on their dashboard, approves it and names
it. Email verification (magic link) is in scope — SMTP/sending is
landed (T1). Fractal's records are explicitly expendable: no migration
burden.

**2026-09-16 amendment (user decisions):**
- The account is keyed by **email for login and a UUID internally** —
  no globally-unique username, no account subdomain root. The signup
  form asking for a "username that becomes your domain" is wrong on
  both counts: an account is not a machine, and a login identity that
  must double as a public hostname is a design error (the UUID key
  also leaves room to attach phone/OIDC login later — deferred, not
  built).
- Machines get **flat** hostnames: `<machine>.proletariat.tech`
  (not `{device}.{username}.{domain}` as this proposal first planned).
  Machine names are globally unique across all customers — the cost of
  the simpler URL, accepted deliberately.
- Enrollment is **invite-URL based**, not box-displayed-code: the
  owner generates an invite link, shares it out-of-band (a paper
  insert in a preinstalled box, an email, a paste into the box's
  "Join network" screen), the machine auto-enrolls when it first
  dials out, and the owner approves + names it from the dashboard.
  This reverses the proposal's original "box-shows-code" decision —
  the premise that reversed it is the preinstalled-shipping use case:
  a headless box that ships to a customer cannot rely on a screen
  someone stands in front of.

If we don't build it: every new customer is an operator touch, remote
access never self-heals on a fresh box, and the "charge for services"
path has no account to bill.

## Flow (end to end)

```
OWNER                        EDGE (proletariat.tech)              MACHINE
─────                        ───────────────────────              ───────
signup: email + password
(no username field)
→ magic link → active

dashboard: "Invite a machine"
→ POST /api/invites
   → 10-char invite code,
     TTL 30d, revocable
→ share https://proletariat.tech/a/{code}
   out-of-band: paper insert in a
   preinstalled box, email, or pasted
   into the box's "Join network" screen
                              machine dials the invite:
                                  POST /api/invite/{code}/begin
                                  {public_key} → PendingEnrollment
                                  status=waiting
dashboard: "This machine is trying
to join your network — [name] approve/deny"
→ POST /api/invite/{code}/approve
   {machine_name}             allocate /128 + WG tunnel
                              create Machine {owner: account UUID}
                              wire WG peer + forwards
                              DNS {machine}.proletariat.tech
                              → mark approved; one-time delivery
                              of {tunnel config, device_token,
                              hostname} on the machine's next poll
     or DENY → request dropped, code burned
                                  GET /api/invite/{code} (poll)
                                  → approved: tunnel config +
                                    device_token + hostname
                                  (consumed on delivery; a re-begin
                                   with the SAME pubkey re-delivers)
     ├─ write /var/lib/fortress/tunnel.json + device-token
     ├─ bring up wg0, forwarder binds
     └─ dashboard: "Paired — main.proletariat.tech"
```

Reboot: the box reads its persisted tunnel state and brings wg0 up with
no user action. Re-key (re-provision): the box calls
`POST /api/device/register` with its `device_token` + new pubkey → peer
rotated on the SAME route (no human, no AdminKey) — this is the gap
ADR-025's "device token" was always meant to close.

## The invite code (decision: 10-char URL, not box-displayed words)

The code is **10 characters, Crockford base32** (no `I/L/O/U`
ambiguity), rendered inside a full URL:
`https://proletariat.tech/a/kowiqmz4xy`. Rationale: the invite travels
**out-of-band to the machine** (paper insert, email, config), not
across a screen the owner must transcribe — so human readability
matters far less than URL ergonomics, and a URL is the one artifact
that works for a headless preinstalled box. Entropy: 32^10 ≈ 50 bits.
This is deliberately *less* than the 5-word code it replaces, because
the code alone grants nothing: a leaked invite only produces a
**pending request on the owner's dashboard**, which the owner must
approve (and name) — the approval gate is the trust anchor, not the
code. Codes are single-use (approve or deny both burn them), TTL 30
days, revocable by the owner from the dashboard.

## Acceptance criteria

- [x] **L0** Account lifecycle: signup (email + password, **no username
      field**) → `pending` → magic-link verify → `active`; the account
      record carries a generated **UUID**; login issues a session
      cookie; logout invalidates it. Passwords are bcrypt-hashed, never
      plaintext; a second signup with the same email is rejected; the
      verify token is single-use + expires. Maps to T2, T4.
      **T4 PROVEN 2026-09-16: `cargo test -p fortress-controlplane` 65
      PASS against a live Redis (incl. `account_record_has_no_username_field`,
      `api_users_round_trip`, web round trips).**
- [x] **L0** Password reset: a logged-out user can request a reset email
      (magic link, single-use + expiring like verify); the reset link
      replaces the password without a session; an unknown email is
      indistinguishable from a known one (no account enumeration). Maps
      to T2, T3.
- [x] **L0** Account deletion unwires, never wipes: `DELETE /api/account`
      removes the account's WG peers + forwards + per-machine DNS +
      device tokens + sessions; the box's local data is untouched (it
      just loses remote access and can re-enroll). Maps to T9.
      **T9 PROVEN 2026-09-16 — see the task block.**
- [x] **L0** Invite lifecycle: a session-auth'd `POST /api/invites`
      creates a 10-char Crockford base32 code (TTL 30d, revocable); a
      machine's `POST /api/invite/{code}/begin {public_key}` creates a
      `waiting` pending enrollment; the owner's approve (session-auth,
      carries `machine_name`) allocates a fresh `/128` + WG tunnel +
      flat DNS under the account, wires the live WG peer + forwards,
      and flips the code to `approved`; the machine's next poll
      receives the tunnel config + `device_token` (one-time delivery,
      consumed on read; re-begin with the same pubkey re-delivers);
      deny burns the code; an expired/used code is rejected. Maps to T6.
      **T6 PROVEN 2026-09-16 — see the task block.**
- [x] **L0** Machine names are globally unique (SETNX), at least 6
      characters, and checked against a reserved-word list; approving a
      duplicate/too-short/reserved name is rejected with a pick-another
      error; the generated code matches the Crockford alphabet. Maps to
      T5, T6. **T5 half PROVEN 2026-09-16: `machine_name_policy` +
      allocation round trip PASS (66 controlplane tests, live Redis);
      the Crockford-code half lands with T6. **Code-format half now
      PROVEN too (T6's `invite_code_is_crockford_and_10_chars`).**
- [x] **L0** `device_token` authorizes re-registration (pubkey rotation)
      without AdminKey; rotation keeps the route; an invalid token 401s.
      Maps to T6. **T6 PROVEN 2026-09-16 (store + API round trips).**
- [x] **L0** Email is behind a `Mailer` trait: `SmtpMailer` (lettre,
      STARTTLS + AUTH) and a `MockMailer` that asserts the message
      (recipient, magic link with the token) in tests. Maps to T1.
- [x] **L0** `POST /signup` (AdminKey) keeps working, now served at
      `/api/wireguard/new` — it creates an owner-less machine on the
      unified model with the same hostname shape (`{name}.{domain}`),
      so the `edge-forward` L2 test and the operator path do not
      break. **Wire shape amended 2026-09-16 (T5): request field
      `name`, response envelope `machine` — the only consumer (the L2
      test) updated in the same task. PROVEN: `edge-forward` L2 PASS
      + `status.sh` 3/3.**
- [x] **L1** `nix flake check` green: SMTP secrets added to
      `secretspec.toml`, `vmtest-wiring` unchanged, `edge-forward`
      passes. Maps to T1, T5. **PROVEN 2026-09-16: `edge-forward` L2
      PASS + `scripts/status.sh` 3/3 after T5 and again after T6.**
- [ ] **L2** The single-VM edge+client vmtest runs the onboarding flow
      end to end: in-VM edge + client, client posts its invite code
      begin, the test approves + names it, the tunnel comes up, and
      `curl https://{machine}.proletariat.tech` through the `/128`
      returns 200. This is the "serving infrastructure is hammered
      down" gate. Maps to T11.
- [x] **L0** Flat per-machine DNS naming: `{machine}.{domain}` + wildcard;
      the reconcile loop enumerates machines (not usernames); no
      account-apex records are created. Maps to T5. **PROVEN
      2026-09-16: DNS unit tests + allocation round trip assert host +
      wildcard only; no apex record is created anywhere.**

## Smallest version

A vertical slice that works for a real second person: an email +
password signup (no username field) verified by a magic link (SMTP
configurable; a console/dev mailer prints the link when SMTP secrets
are absent), a dashboard that generates an invite URL, a box that
auto-enrolls against the invite and polls, an approval screen where
the owner names the machine, and the box coming up on its tunnel.
`POST /signup` (AdminKey) stays as the operator path. No QR, no
billing, no operator-generated invites at order time (the "preinstalled
box ships with an invite insert" path is the same flow with a
different out-of-band channel — nothing extra to build; an
order-time invite generator is explicitly deferred).

## Alternatives considered

- **Keep one-customer-per-box (account = box)** — case for: no data-model
  change. Case against: the user chose "one account, many machines"; the
  flat per-machine subdomain model is where "pair a NEW machine" has
  room to grow. Rejected by decision.
- **Email is login id only, no verification** — case for: no SMTP
  dependency, fastest. Case against: the user chose magic-link
  verification, and billing (a stated goal) needs a reachable, owned
  email anyway. Rejected by decision.
- **Box-shows-5-word-code (the proposal's original decision, reversed
  2026-09-16)** — case for: no invite has to travel out-of-band; the
  code is readable-aloud; works for a box the user physically sets up.
  Case against: the preinstalled-shipping use case breaks the premise —
  a headless box shipped to a customer needs an enrollment path that
  does not require someone at its console, and the owner is not
  necessarily in the same room as the box. Reversed by decision.
- **Server-generated pairing id, box consumes it (originally rejected,
  now the winner in URL form)** — case for: central entropy, guaranteed
  uniqueness, revocable, and the URL is shareable to a machine the
  owner never touches. Case against: the code must reach the machine
  out-of-band, and a leaked URL produces a pending request — but that
  is exactly what the approve/deny gate is for. Won on the preinstalled
  premise.
- **Nested hostnames `{machine}.{account-root}.{domain}`** — case for:
  no global namespace to squat; names only need per-account uniqueness.
  Case against: the user chose flat `<machine>.proletariat.tech` —
  shorter, cleaner URLs, and the account stops needing any public
  identifier. Cost accepted: machine names are globally unique, first
  come first served, and squatting is real (see strongest objection).
- **QR code** — case for: zero typing on mobile. Case against: the
  machine, not the owner's phone, is the enrollment target; a URL is
  the machine-consumable form. Deferred out of scope.
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
  identity models (customer vs account+machine) is exactly the "second
  source of truth" debt this project bans. Unify: `Customer` →
  `Machine` with an `owner: Option<Uuid>` field; the AdminKey `/signup`
  creates an owner-less machine with the same hostname shape.
- **UUID-only accounts (email not stored as key)** — case for: pure
  opaque identity, free email change. Case against: the landed T2
  already keys accounts by email and email is what users log in with;
  the UUID rides *inside* the record as the owner reference. Email
  change is a rare migration, not a schema need. Rejected (UUID-in-
  record, email-as-key).
- **Inactivity-based name release (free tier, 2 months quiet)** —
  case for: recycles squat-once names without billing machinery. Case
  against: silently breaks legitimate users (a box offline for a
  summer comes back to a name a stranger owns — bookmarks, shared
  links, muscle memory all point elsewhere); "inactivity" is ambiguous
  (machine offline? account idle? no tunnel data?) with invisible
  clock starts; "free tier" doesn't exist yet (billing is out of
  scope, only a `plan` field); and registrars release names of
  deleted/expired registrations, never of live accounts gone quiet.
  Names already recycle on machine delete. **Rejected — revisit only
  in the billing arc, and even then prefer a loud pre-reclaim warning
  over silent release.**

Why the winner wins: the invite URL is the only enrollment artifact
that works for a headless preinstalled machine; account (UUID + email)
→ machines is the model billing and multi-machine growth build on, and
the UUID leaves OIDC/phone login attachable later without a migration;
flat hostnames are the simplest URL the customer sees; the `Mailer`
trait keeps SMTP honest (provider swappable by secret, mockable tests);
unifying on `Machine` avoids a parallel identity store.

## Architecture decisions

- **New ADR-032 (advances ADR-025's v3 shape; corrects this proposal's
  original ADR-028 reference, which collides with the LAN ADR):** the
  control plane moves from one-`Customer`-per-box to **Account →
  Machines**. An account is keyed by email (login), carries a
  generated UUID (the owner reference — and the future auth-provider
  attach point), and owns any number of machines. A machine is a
  home-server box with its own `/128`, WG tunnel address, pubkey, and
  flat hostname `{machine}.{domain}`. Redis stays the store (ADR-025).
  The account's `username` field (landed T2) is removed; Fractal-era
  records are expendable.
- **Enrollment protocol (owner-generated invite URL).** The owner
  creates a **10-char Crockford base32 invite** (TTL 30d, revocable,
  single-use) and shares `https://{domain}/a/{code}` out-of-band. The
  machine POSTs `/api/invite/{code}/begin {public_key}` → a `waiting`
  PendingEnrollment; the owner's dashboard shows it
  ("This machine is trying to join your network — name it, approve or
  deny"); approve names the machine, allocates the route, creates the
  Machine, and flips to `approved`; the machine polls
  `GET /api/invite/{code}` and receives tunnel config + `device_token`
  + hostname in a **one-time delivery** (consumed on read; re-begin
  with the same pubkey re-delivers). Approve or deny burns the code.
  The code grants a *pending request only* — the approval gate is the
  trust anchor.
 - **Flat DNS moves to per-machine.** `upsert_machine`/`remove_machine`
   naming (`{machine}.{domain}` + wildcard) replaces `upsert_customer`;
   the reconcile loop enumerates machines. Account-apex records are
   dropped. Machine names are globally unique (SETNX
   `fortress:machine:{name}`), at least **6 characters** (a cheap
   anti-squat: drains the vanity value of `main`/`home`/`box`), and
   reserved names (apex, `www`, `mail`, service names) are rejected at
   approval time. Names return to the pool only when the machine is
   deleted (delete already unwires DNS + drops the key); inactivity
   based release was considered and rejected (see alternatives) —
   revisit only when billing exists.
- **Device token (closes ADR-025's deferred gap).** Enrollment returns a
  long-lived `device_token` the box persists; `POST /api/device/register`
  accepts it (instead of AdminKey) to rotate the box's pubkey on the
  same route. Stored hashed (SHA-256), same discipline as `AdminKey`.
- **Sessions live in Redis** (`fortress:session:{token}` → account,
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
- **Allocation is shared.** The current `signup` core is refactored into
  `allocate_machine(owner, machine_name, public_key, ...)`; both the
  AdminKey `/signup` path and the invite approval call it. One route +
  forward + DNS code path (the DRY move; also fixes the redundant paths).
- **Operator path survives.** `POST /signup` (AdminKey) stays, creating
  an owner-less machine whose hostname is `{name}.{domain}` (wire
  shape unchanged) so the `edge-forward` L2 test and operator flow keep
  working. Invite enrollment is the customer path.
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
      (list, AdminKey) and `/api/wireguard/:name` (delete, AdminKey).
      The operator provisioning path is `POST
      /api/wireguard/new` (was `POST /signup`); T6 invite enrollment
      lives at `/api/invites` + `/api/invite/{code}*` and device
      rotation at `/api/device/register`, all under `/api/`.
      (Amendment note: the operator path's `username` field is now
      semantically the machine `name` — wire shape unchanged.)
  - **T5's "same wire shape"** now means "same JSON request/response at
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
  (session-auth) removes every machine's WG peer + forwards + per-machine
  DNS + device tokens + sessions. The box's local data is the box's —
  it is not touched; the box simply loses remote access (its tunnel
  dies, its `device_token` is revoked) and can be re-enrolled under a new
  account. This matches the "remote access is the product; the box's
  data is the customer's" line.

## Tasks

### T1: Mailer (SmtpMailer + MockMailer) + SMTP secrets
**Depends on:** none
**Verification:** `cargo test -p fortress-controlplane` green; MockMailer
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

### T4: Account UUID + signup without username
**Depends on:** T2
**Status:** DONE 2026-09-16 — `AccountRecord` carries `uuid` (v4), the
`username` field and `fortress:username:{u}` SETNX are gone, the
signup form + `/api/users/register` take email+password only,
`AccountError::InvalidUsername`/`DuplicateUsername` deleted,
`account_error_message`/`users_api_error` trimmed. Proof: 65
controlplane tests PASS against a live Redis (incl. the new
`account_record_has_no_username_field` tripwire + web/API round
trips). Verification repair noted: two stale landing assertions
("Signed in as" / "Create an account") predated the 2026-09-15 zine
restyle and only ever passed when REDIS_URL was unset (tests
silently skipped) — updated to the real DOM text.
**Files:** `crates/controlplane/src/controlplane/account.rs`,
`crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/web.rs`

### T5: Machine model + shared allocation + flat DNS + operator /signup compat
**Depends on:** T4
**Status:** DONE 2026-09-16 — `Customer`→`Machine` (`name`, `owner:
Option<String>`, skip_serializing_if none), `allocate_machine(owner,
name, public_key)` is the single allocation core (operator handler
passes `owner: None`), Redis keys `fortress:machine:*` +
`fortress:machines`, `validate_machine_name` (≥6 chars + reserved
words incl. product service labels), DNS fns `upsert_machine`/
`remove_machine`/`machine_hostname` (`{name}.{domain}` + wildcard),
reconcile enumerates machines. **Plan amendment (reality check):**
the operator wire shape WAS renamed — request field `username`→
`name`, response envelope `customer`→`machine` — because the only
consumer (the `edge-forward` L2 test) is in this task's file list;
the AC's real invariant (operator path works, hostname
`{name}.{domain}`) is preserved. Also caught by the new tripwire:
"jellyfin" was missing from the reserved list the first time — the
test failed before anything shipped. Proof: 66 controlplane tests
PASS (live Redis, incl. `machine_name_policy` + the allocation round
trip with owner carried + operator idempotency/rotation) +
`edge-forward` L2 PASS + `status.sh` 3/3.
**Files:** `crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/dns.rs`,
`nix/tests/edge/default.nix`

### T6: Invite lifecycle API + device token + rotate
**Depends on:** T5
**Status:** DONE 2026-09-16 — `pairing.rs` (new module): invite
records (`fortress:invite:{code}`, 30d TTL), 10-char Crockford base32
codes, one-time delivery envelope (`fortress:invite-delivery:{code}`,
24h TTL, GETDEL; same-pubkey re-begin re-arms a FRESH token — a missed
delivery is self-healing and the old token dies), approve/deny/revoke
guarded on owner email, `allocate_machine` is the only route-creation
path, `device_token` SHA-256-hashed on the Machine record, `POST
/api/device/register` rotates the pubkey on the same route without
AdminKey (constant-time hash compare). **Plan amendment (path):** all
invite endpoints live under `/api/invites/{code}/...` (one resource
prefix), not `/api/invite/{code}` as first written; the machine-facing
URL stays `https://{domain}/a/{code}` (T7 web page → API). Proof: 74
controlplane tests PASS against a live Redis (incl. `api_invites_
round_trip` over the HTTP API: 401s without session, create→begin→
approve→one-time poll→token rotation→wrong-token 401; plus store-level
round trips for begin/approve/deny/revoke/re-arm/ownership) +
`edge-forward` L2 PASS. Clippy: net warnings vs baseline reduced.
**Files:** `crates/controlplane/src/controlplane/pairing.rs`,
`crates/controlplane/src/controlplane/mod.rs`

### T7: Web UI — signup trim + devices page + invites + approval screen
**Depends on:** T6
**Status:** DONE 2026-09-16 — signup form trim landed with T4. New:
`/machines` dashboard (machines list with hostnames, invite list with
status badges + candidate pubkey, "Generate invite link" form, approve
form with the name input, deny + revoke buttons, the fresh code's
share URL highlighted; session-gated with a redirect to /login);
`/a/{code}` public join page (handoff instructions for the human who
lands there); web form routes `/auth/invite[...]` driving the same
`ControlPlane` methods as the API; the share URL derives from the
injected `root_domain`, never a hardcoded zone; the landing's
logged-in CTA points at `/machines`. **UI copy note:** the approval
card renders the name input + approve/deny (the proposal's exact
"This machine is trying to join your network" line became
"Candidate: <pubkey>" + the name input — same gate, denser copy).
Proof: 77 controlplane tests PASS (live Redis) incl.
`machines_page_requires_session` (anonymous → /login),
`machines_dashboard_invite_approve_flow` (create → fresh code shown →
candidate appears → approve names it → machine listed with hostname →
taken-name surfaced), `join_page_renders_instructions`,
`signup_verify_login_logout_web_round_trip`.
**Files:** `crates/controlplane/src/controlplane/web.rs`
**Files:** `crates/controlplane/src/controlplane/web.rs`

### T8: Client invite-enrollment module (box side)
**Depends on:** T6
**Status:** DONE 2026-09-16 — `pairing.rs` (new client module):
`InviteConfig` (invite URL + static edge endpoint/allowed-ips, parsed
into base + code, malformed URLs fail fast), the `EdgeClient` trait
(async-trait; `HttpEdgeClient` hits `/api/invites/{code}/begin` +
`/poll` + `/api/wireguard/pubkey` + `/api/device/register`),
`enroll` (begin → poll with injectable interval/max-polls → persist
`tunnel.json` + `device-token` 0600), `rotate` (token-authorized
pubkey rotation), `substitute_tunnel_ip`. **Plan amendment (mechanism
the task didn't name):** forwards may reference the runtime-assigned
tunnel IP via the `{tunnel_ip}` placeholder in `dest_addr`;
`app.rs` substitutes it after the tunnel state resolves, and fail-fast
errors if a placeholder survives with no tunnel state. Boot priority:
persisted `tunnel.json` → config `invite` (enroll) → legacy static
`tunnel`; `tunnel` + `invite` together is a config error. An enrolled
box never re-enrolls (persisted state wins; no edge dependency at
boot). Proof: `cargo test -p fortress-client` 71 PASS (mock edge, no
live network: poll-until-approved round trip with state + 0600 token
persistence, denied terminal, timeout leaves nothing persisted,
rotate uses the persisted token with the derived pubkey, invite-URL
parse, config shape, substitution) + workspace build green.
**Files:** `crates/client/src/pairing.rs`,
`crates/client/src/app.rs`, `crates/client/src/tunnel.rs`

### T9: Account deletion (unwire, never wipe)
**Depends on:** T6
**Status:** DONE 2026-09-16 — `account_delete` (account.rs): unwires
every machine (shared delete path: peer + forwards + DNS + record with
its token hash), drops every invite the email owns, sweeps ALL sessions
valued at the email (cursor-complete SCAN — the one-page version was
caught by the test in a shared keyspace), drops the record last.
`DELETE /api/account` (session cookie auth) + web
`POST /auth/account/delete` with a type-`DELETE` confirmation field;
confirmed → redirect + cleared cookie. There is no `/api/me` (the AC's
example endpoint); the proof is "the session can no longer reach owner
ops + login is impossible + the machine record is absent" — same
invariant. Box data untouched (nothing writes to the box). Proof: 79
controlplane tests PASS (live Redis) incl. `account_delete_unwires_
machines_and_sessions` (store level) + the API round-trip tail
(200 → owner ops 401 → machine gone → login 401) +
`account_delete_web_flow` (unconfirmed refused, confirmed clears the
session) + `edge-forward` L2 PASS.
**Files:** `crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/web.rs`

### T10: Single-VM edge+client wiring in vmtest (foundation)
**Depends on:** none
**Verification:** `nix flake check` green; `vmtest.nix` enables the real
`services.fortress-client` module + an in-VM edge unit (mirror the
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
+ client run the full flow (signup via console mailer, invite generated,
machine begins, test approves + names, wg0 up, `curl
https://{machine}.proletariat.tech` through the `/128` → 200),
new assertions in `vmtest-bootstrap.sh`; `edge.nix` gains the SMTP relay
env + DNS TXT records for SPF/DKIM.
**Files:** `nix/tests/default.nix`, `scripts/vmtest-bootstrap.sh`,
`remote-infra/system-manager/edge.nix`, `remote-infra/tofu/dns.tf`

## Strongest objection

**The flat machine namespace is a squatter's playground, and the
approval gate makes it the customer's problem.** Machine names are now
globally unique across all customers — first-come-first-served on
`{anything}.proletariat.tech` — so a customer (or a drive-by signup
farm) can squat generic names (`jellyfin`, `media`, `home`, `admin`)
before the customer who wants them, and the approval-time
pick-another-name error is the only recourse. Combined with the free
signup this is a real brand/typo-squat vector on the product's own
namespace, and the reserved-word list is a whack-a-mole defense. The
honest counterargument for flat naming is that the URL the customer
types is the entire product surface of remote access, and
`main.proletariat.tech` is the difference between "I own a machine on
the internet" and "I own a path under someone else's namespace" — but
the honest cost is that name collisions become support tickets the day
the customer count passes double digits, and at scale this decision
probably reverses (either a paid-name tier or a per-account namespace
segment). The second residual: the invite URL only produces a *pending
request*, which makes the approval screen the highest-value social-
engineering target — an attacker who can phish one blind "approve"
owns a route into the victim's tunnel. A machine's pubkey is shown on
the approval screen but is opaque to humans, so there is no out-of-band
verification a normal person will actually perform. Defense today:
codes are single-use, 30d TTL, revocable, and 50-bit; defense to build
when real customers exist: show the machine's IP/geolocation or a
human-chosen fingerprint at enrollment so approval is an informed
click. Also inherited unchanged: **email verification is gated on
outbound SMTP deliverability** — a magic link that lands in spam means
a signup that "worked" with a customer never able to activate; SPF/DKIM
in the zone we own + a swappable relay secret mitigates, but a real
relay's behavior is only proven by the first real signup — that first
signup should be the demo's, not a paying customer's.

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
  `services.fortress-client` and has no in-VM edge unit — STATUS "Next
  move 7" planned it but it never landed. The onboarding e2e (T11)
  depends on it. Added as T10.
- **amon-sul is gone.** `nixosConfigurations/amon-sul.nix` + custom/
  deleted and `amonSul` removed from `flake.nix` (matches "nuke
  fractal"). STATUS entries for amon-sul (matrix-synapse, jellarr
  bootstrap, admin env wiring, migration) are moot and should be pruned.
- **The pairing-code type changed mid-flight** (chars → 5 words, no QR)
  after the first write; the flow diagram, AC, alternatives, and T5–T7
  were updated to match. No residue found (grep verified).

## Amendment log — 2026-09-16 (invite-URL enrollment, UUID accounts)

Trigger: the customer-facing signup at `proletariat.tech/register`
still asked for a username that "becomes your domain" — inaccurate
under the account→machines model (an account is not a machine; one
account owns many machines). User decisions in session:

1. Account = email login + internal UUID; no globally-unique username.
   Phone/OIDC login is designed-for (UUID as the attach point),
   deferred, not built.
2. Flat hostnames: `<machine>.proletariat.tech` — globally unique
   machine names, cost accepted (squatting risk lives in the strongest
   objection).
3. Enrollment via owner-generated 10-char invite URL
   (`{domain}/a/{code}`), machine auto-enrolls (preinstalled-box use
   case), owner approves + names it on the dashboard. This reverses
   two written decisions: box-shows-5-word-code and nested
   `{device}.{username}.{domain}` DNS. The old premise ("the box must
   show a code on a screen") does not hold for a headless shipped box.

Task renumber: old T4 (device model) → T5; old T5 (pairing API) → T6;
old T6 (web UI) → T7; old T7 (client) → T8; old T8 (deletion) → T9;
old T9 (per-device DNS) merged into T5; T10/T11 unchanged. T1–T3
landed unchanged. ADR reference corrected 028 → 032 (028 is the LAN
ADR; 031 pending on i2p-resilience).

**Addendum, same session (naming policy):** machine names get a
6-character minimum (cheap anti-squat; reserved-word list covers the
service names min-length can't); the user-proposed inactivity-based
release (2 months quiet on free tier) was considered and **rejected**
— silent breakage of legitimate offline boxes, ambiguous "inactivity,"
and premature free-tier machinery. Names recycle on machine delete
only; inactivity-release may be revisited in the billing arc.
