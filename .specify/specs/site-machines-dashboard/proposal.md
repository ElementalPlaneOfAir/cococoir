# Site machines dashboard — the owner's invite/approve surface on the real backend

Status: proposal (2026-09-26). Covers the topcoat arc's **T4 + T6 merged**
(they share one dependency: the forwarder global) **plus T7** (the nix
cutover — user call 2026-09-26: fold it in, no two-edge-binary window).
T8 (delete poem's web + the `fortress-edge` binary) is the immediate
follow-up once the cutover is L2-proven.

## Premise

Interview answers (2026-09-26):

- **Why this? Why now?** The shared landing page's "Go to my machines"
  CTA links to `/machines`, which **404s on the site today**
  (`crates/web-ui/src/lib.rs:380`; the site registers no such page,
  `crates/site/src/app.rs:11-37`). `/machines` is the last
  customer-facing surface the poem controlplane still owns
  (`crates/controlplane/src/controlplane/web.rs:385-507`, handlers
  `1004-1154`), and the topcoat arc's documented next move is T4 then T6
  (`docs/STATUS.md:613-625`).
- **What if we don't build it?** The new site stays a marketing page +
  auth forms: a customer can create an account and sign in, but cannot
  invite or approve a box. T8 (delete poem's web) cannot land, so poem
  stays in the tree indefinitely. The product's core remote-access setup
  loop is unreachable on the site.
- **What do we cut first if over budget?** `deny` and `revoke` (keep
  `approve`). They are cheap parity but not on the customer's happy path.
  Never cut the session gate.
- **Smallest version a real customer feels:** log in on the site,
  **generate an invite link**, have a box redeem it, **approve it with a
  name**, and **see it listed**. That is the acceptance bar.

### The two findings that forced the T4+T6 merge

1. **The forwarder global is the coupling.** `invite_approve` →
   `allocate_machine` → `forwarder()`, a `OnceCell` that **panics if
   uninitialized** (`crates/controlplane/src/controlplane/mod.rs:820-823`,
   `450`). The site's `main.rs` builds a *local* `ControlPlane` via
   `with_deps` and never calls `init_globals`, so the forwarder is never
   seeded: a `/machines` approve button would panic at request time.
   Tests hide it with `set_forwarder_for_tests()`
   (`crates/site/src/api.rs:434`). T4 cannot ship a working approve
   before T6's real boot.
2. **`#[shard]`/`#[procedure]` are the wrong tool, and cost a build
   step.** They are real topcoat 0.8.1 APIs, but the `runtime` + `asset`
   features are off (`crates/site/Cargo.toml:21`). Enabling them requires
   `assets/manifest.toml` from the topcoat bundler, `.runtime()` +
   `.assets(...)`, a runtime `<script>` in the shell, and an asset base
   — none of which exist in this repo. STATUS pre-authorised the
   fallback: plain form POST + full page reload (`docs/STATUS.md:618-620`).
   The existing poem dashboard is already that shape, as is the client
   editor, and the JS-free path keeps `pages_have_no_external_asset_origins`
   honest. Decision: **plain form POST + 303 PRG. No shards.**

## Acceptance criteria

- [ ] **L0** `cargo test --workspace` green. New route tests:
      anonymous `GET /machines` → 303 `/login`; authenticated GET renders
      the account's machines and invites; `POST` create-invite → 303;
      `POST` approve names the machine and it appears; `POST` deny and
      `POST` revoke flip status; `GET /auth/logout` clears the cookie.
      The `no_form_literal_omits_post` tripwire
      (`crates/site/src/lib.rs:238`) scans the new page file. Maps to T4.
- [ ] **L0b** `nix build .#checks.x86_64-linux.redis-tier-compiles` green
      (T0; the store-backed tier this arc's tests lean on must compile).
- [ ] **L1** `nix flake check` all-pass. The site package still builds
      `bin/fortress-site`; the new L2 test is registered. Maps to T2, T5.
- [ ] **L2** A new nixosTest boots `fortress-site` on the **real** boot
      path (secrets from `edge.env`, real `wg0`, real Redis) and proves
      the customer flow: anonymous `/machines` → 303 `/login`;
      authenticated render; create invite; machine `begin`; owner approve
      with a name; the machine appears and its peer is in `wg0` with the
      `/128` forward bound. Maps to T2, T4, T5.
- [ ] **L2-cutover** The existing `edge-forward` nixosTest passes against
      `fortress-site` — same data path, same store-held-key equality
      (served pubkey == the `edge.env` key), same live `/128` bind. Its
      assertions are *unchanged* in what they claim; only the binary
      moves. This is the arc's gate. Maps to T6, T7, T8.
- [ ] **L0-cutover** The site's axum `/api` serves the ported
      operator/health routes with the admin bearer enforced (401 without,
      200 with) and the wire shapes pinned. Maps to T6.
- [ ] **Behavioural** On a non-`--dummy` boot the site resolves the
      store-held WG identity: the pubkey it serves equals the edge's
      `WG_PRIVATE_KEY`-derived pubkey (the same assertion the edge L2
      test makes, `nix/tests/edge/default.nix:288`). Maps to T2, T5.
- [ ] **Guardrail** `--dummy` on the site compiles only into debug
      builds; a release build rejects it (mirroring
      `crates/controlplane/src/bin/fortress-edge.rs:245-249`). Maps to T2.
- [ ] **No new customer-facing option.** The dashboard is reached from
      the landing CTA; nothing in the 50-line surface changes. Maps to T4.

## Smallest version

A `/machines` page on the site, behind the existing session cookie, that
renders the account's machines and invites and offers: generate an invite
link (with the share URL), approve a waiting machine with a name, deny /
revoke a waiting invite, and sign out. It renders **the same component the
poem dashboard renders** (moved to `web-ui`, so there is one markup
source). The site's boot switches from injected mocks to the process
globals, so approve actually allocates. Nothing else: no shards, no
assets, no apply/rebuild, no observability spine.

## Alternatives considered

- **Topcoat `#[shard]`/`#[procedure]`** — case for: typed args, partial
  re-render, the "modern" topcoat path. Case against: requires the
  `runtime`+`asset` features, an `assets/manifest.toml` from a bundler
  step this repo lacks, `.runtime()`/`.assets()` wiring, a runtime
  `<script>` (a new external-origin surface to police), and topcoat's
  client reactivity is self-described as early-stage. The dashboard is
  CRUD forms; full reload is a feature (works with JS disabled). Winner:
  form POST. Revisit only if the dashboard grows real interactivity.
- **Keep the poem dashboard and reverse-proxy it from the site** — case
  for: no port. Case against: contradicts the entire topcoat arc; leaves
  two web stacks and two auth surfaces forever. Rejected.
- **Put the manager on the box's local dashboard (`crates/client`
  `:3000`) instead** — case for: the box already has an authenticated
  dashboard. Case against: machine management is an *account* concern
  (which machines belong to me, across many boxes), not a box-local one;
  the customer reaches it from the public site, not a LAN address.
  Rejected.
- **T4 before T6** (the documented order) — case for: matches STATUS.
  Case against: the approve button panics (finding 1). Rejected: merge.
- **Read `secret::root_domain()` for the share URL instead of adding an
  accessor** — case for: zero code. Case against: it panics in dummy mode
  (the `SECRETS` LazyLock is never resolved there,
  `crates/controlplane/src/controlplane/secret.rs:42-53`). Rejected: add
  `ControlPlane::root_domain()`.
- **Duplicate the machines markup in the site, delete the poem copy in
  T8** — case for: no refactor of a doomed component. Case against: two
  divergent dashboards until T8, which is exactly the duplication the
  constitution bans, and pixel drift is a real risk (the Landing parity
  fix, `docs/STATUS.md:182-199`, was for this same class). Rejected: move
  the component to `web-ui` now, primitive props.

## Architecture decisions

- **No new ADR.** Extends ADR-033 (topcoat presentation pivot) and the
  axum/utoipa + topcoat split already recorded in
  `crates/site/src/lib.rs:4-18`. The site becomes the edge's *process*;
  the nix cutover is a separate step (T7).
- **`SiteBackend.cp` becomes `&'static ControlPlane`.** The process
  global is the single control plane that `init_globals` builds and that
  `allocate_machine`'s `forwarder()` assumes. `ControlPlane` methods take
  `&self`, so call sites (`backend.cp.invites_of(...)`) are unchanged.
- **The dashboard component lives in `web-ui` with primitive props.**
  `MachinesProps` currently carries `controlplane::Machine` /
  `InviteRecord`; `web-ui` cannot depend on `controlplane` (controlplane
  depends on web-ui — a cycle). So `web-ui` gets owned/primitive rows
  (`MachineRow { name, hostname }`, `InviteRow { code, status_label,
  device_pubkey }`), and each surface maps its domain types in. This is
  the `LandingProps` pattern (`crates/web-ui/src/lib.rs:355-383`).
- **One markup source.** `web-ui` exports `machines_html()` (the
  `landing_html` precedent, `crates/web-ui/src/lib.rs:633-635`); the
  poem surface renders the same `Node`, so the two surfaces cannot drift.
- **The share URL needs the domain.** `ControlPlane::root_domain()` is a
  new public accessor (the field is `pub(crate)`,
  `crates/controlplane/src/controlplane/mod.rs:321`), so the dashboard
  renders `https://{root_domain}/a/{code}` without touching `SECRETS`.
- **Sign-out is a GET.** The shared landing emits
  `<a href="/auth/logout">` (`crates/web-ui/src/lib.rs:371`) but the site
  serves only `POST /logout` (`crates/site/src/pages/auth.rs:269`) — so
  the landing's sign-out is broken on the site in *both* path and method.
  The site gains `GET /auth/logout` (matching the controlplane's
  `web.rs:1225`), which is a link, not a form, so the form-safety
  tripwires are unaffected.

## Tasks

### T0: `redis-tests` compiles, with a guard — DONE 2026-09-26
- [x] The gated tier was red-on-compile (`TEST_EDGE_WG_PRIV` deleted as
      "unused" by the default lint) with every check green. The four
      usages now read the byte-identical `DUMMY_EDGE_WG_PRIV`; new L0
      check `redis-tier-compiles` compiles the tier. Proven by
      `nix build .#checks.x86_64-linux.redis-tier-compiles`.
**Depends on:** none
**Verification:** `nix build .#checks.x86_64-linux.redis-tier-compiles`.
**Files:** `nix/tests/default.nix`, `crates/controlplane/src/controlplane/mod.rs`

### T1: controlplane exposes the boot values the site needs — DONE 2026-09-26
Add `pub fn root_domain(&self) -> &'static str` to `ControlPlane`.
`mail::mailer()` already exists (`mail.rs:219`) — confirm it is reachable
from the site after T2.
**Depends on:** none
**Verification:** L0 — a unit test asserts the accessor returns the
concrete plan's domain (and `DUMMY_ROOT_DOMAIN` for a dummy plan). L1.
**Files:** `crates/controlplane/src/controlplane/mod.rs`

### T2: the site boots on the process globals (real WG/DNS, store-held key) — DONE 2026-09-26 (L0)
`SiteBackend.cp: ControlPlane` → `&'static ControlPlane`. `main.rs`:
install the rustls provider; parse `--redis-url / --subnet / --wg-subnet
/ --addr / --ipv6-iface` plus **value-less `--dummy` under
`cfg!(debug_assertions)` only**; resolve the store URL exactly like the
edge (`--redis-url` wins; dummy → `redis://127.0.0.1:6379`; else
`secret::redis_url()`); `init_globals(...).await`; build the backend from
`control_plane()` + `mail::mailer()`. Update the `test_backend` fixtures
in `lib.rs`/`api.rs` to the `&'static` shape (they already leak, so this
is a type change, not a rewrite).
**Depends on:** T1
**Verification:** L0 — `cargo test --workspace`; a debug test asserts
`--dummy` is value-less and does not swallow `--subnet`, and a
`#[cfg(not(debug_assertions))]` test asserts a release build rejects
`--dummy` (the edge's tripwire, mirrored). L2 (T5) proves the real boot.
**Files:** `crates/site/src/main.rs`, `crates/site/src/lib.rs`,
`crates/site/src/api.rs`

### T3: move the machines component to `web-ui` (one markup source) — DONE 2026-09-26
Move `MachinesProps`/`MachinesPage` out of
`crates/controlplane/src/controlplane/web.rs:373-507` into
`crates/web-ui/src/lib.rs`, retyped to primitive rows; export
`machines_html()`. Rewrite the poem surface to map `Machine`/`InviteRecord`
into the primitive props and render the shared component (behaviour
byte-identical — the poem page's output must not change).
**Depends on:** none
**Verification:** L0 — a `web-ui` test renders `machines_html()` for the
empty, waiting, and approved cases and asserts the status stamps + share
URL; the existing `pages_have_no_external_asset_origins` and
`machines_dashboard_invite_approve_flow` (`web.rs:1939`) stay green
against the moved component. L1.
**Files:** `crates/web-ui/src/lib.rs`,
`crates/controlplane/src/controlplane/web.rs`

### T4: the site's `/machines` page, routes, and sign-out
New `crates/site/src/pages/machines.rs`: `GET /machines` (session-gated
via `account::current_session`; anonymous → 303 `/login`), `POST
/machines` (create invite → 303 `/machines?invited={code}`), `POST
/machines/{code}/approve` (`name`), `POST /machines/{code}/deny`, `POST
/machines/{code}/revoke` — all 303 PRG, all reaching `backend.cp`. Add
`GET /auth/logout` (clears the session, 303 `/`). Register the pages in
`app.rs` and add `machines.rs` to the `no_form_literal_omits_post`
`sources` array.
**Depends on:** T2, T3
**Verification:** L0 — the route tests in the acceptance criteria, driven
through `server::app` with a leaked store-backed backend (the
`enrollment_e2e_tests` pattern, `crates/site/src/api.rs:426`), including
anonymous-bounce and the approve flow. The form-method tripwire passes.
**Files:** `crates/site/src/pages/machines.rs`,
`crates/site/src/app.rs`, `crates/site/src/lib.rs`

### T5: L2 nixosTest — invite + approve on the real backend
New `nix/tests/site-machines/default.nix`: one VM with Redis, real `wg0`
(shared identity), `edge.env`, and `fortress-site` on a systemd unit
mirroring `edge.nix` (WorkingDirectory `/etc/fortress`, EnvironmentFile,
`wireguard-tools` on PATH). Seed an Active account + session in Redis via
`redis-cli` (the `account.rs` record shape), then: assert anonymous
`/machines` → 303; authenticated GET 200; create invite; `POST
/api/invites/{code}/begin` with a generated WG pubkey; approve with a
name; assert the machine lists and `wg show wg0` has the peer and the
`/128` is bound. Register the test in `nix/tests/default.nix`.
**Depends on:** T2, T4
**Verification:** L2 — `nix flake check` runs `site-machines`; it must
print `site-machines: PASS`. Also asserts the served pubkey equals the
`edge.env`-derived pubkey (the store-held-identity property).
**Files:** `nix/tests/site-machines/default.nix`, `nix/tests/default.nix`

### T6: the edge's operator + health API moves onto the site's axum tree
The site's `/api` tree (`crates/site/src/api.rs:212-220`) currently has
only the machine-facing pairing routes. The cutover needs the rest of the
poem OpenAPI surface (`crates/controlplane/src/controlplane/mod.rs:1458-1468`):
`POST /api/wireguard/new` (→ `allocate_machine`), `GET /api/wireguard`
(→ `list`), `DELETE /api/wireguard/:name` (→ `delete`), and `GET
/api/healthz` `/api/readyz` `/api/status` (status = `forwarder().stats()`),
behind an axum admin-bearer extractor reusing the constant-time
`verify_token` (`crates/controlplane/src/controlplane/auth.rs:48-52`).
**Do not port `/api/users/*`** — `crates/site/src/pages/auth.rs` already
owns those operations as topcoat pages, and no customer client calls the
JSON variants.
**Depends on:** T2
**Verification:** L0 — axum route tests per path incl. admin-bearer
401/200; `wire_contract_tripwires` (`crates/site/src/lib.rs:283-335`)
extended to pin the ported shapes. L2 via T8.
**Files:** `crates/site/src/api.rs`, `crates/controlplane/src/lib.rs`
(any newly-needed re-exports), `crates/site/src/lib.rs`

### T7: cut the deployment over to the site binary
`ExecStart` in the system-manager unit and its tofu template switches from
`fortress-edge` to `fortress-site` (same flags, plus `--ipv6-iface`; same
WorkingDirectory/EnvironmentFile). `nix/packages/fortress/default.nix`
promotes `fortress-site` to a first-class output (meta description /
mainProgram note — the `fortress-edge` name there was 2026-09-19 stale
documentation for a workspace that already builds both). The box module
(`nix/nixos-modules/client.nix`) is untouched.
**Depends on:** T6
**Verification:** L1 — `edgeStoreWiring` (`nix/tests/default.nix:33-47`)
stays green against the changed template (no local redis, no
`--redis-url`). L2 — the `edge-forward` nixosTest (T8) passes against the
new binary.
**Files:** `remote-infra/system-manager/edge.nix`,
`remote-infra/tofu/templates/edge.nix.tftpl`,
`nix/packages/fortress/default.nix`

### T8: cut the dev loop over and flip the L2 proof
Delete the `edge` process from `nix/dev/process-compose.nix` (`site` is
the single server, on `--dummy`); flip `nix/tests/edge/default.nix`'s
`fortress-edge.service` to `fortress-site` with the same assertions —
the data path, the store-held-key property (`default.nix:288`), and the
live `/128` bind are the arc's gate.
**Depends on:** T7
**Verification:** L2 — `nix flake check` runs `edge-forward` against
`fortress-site` and it PASSes; the site's `--dummy` dev boot serves the
dashboard.
**Files:** `nix/dev/process-compose.nix`, `nix/tests/edge/default.nix`

### T9: docs
Record the merged arc, the `--dummy`/store-URL parity, the cutover, and
the T10 follow-up (delete poem's web + the `fortress-edge` binary) in
STATUS.md.
**Depends on:** T8
**Verification:** `bash scripts/status.sh` 3/3; STATUS names its proofs.
**Files:** `docs/STATUS.md`

## Strongest objection

**Folding T7 in couples a customer feature to a deployment cutover, and
the blast radius is the edge's public API.** The dashboard (T1-T5) is
independently valuable; the cutover (T6-T8) rewrites the edge's operator
and health surface from poem-openapi to axum/utoipa and repoints
production `ExecStart` at a binary that has never served production
traffic. If the port misses a wire shape or the health contract drifts,
the failure mode is the *edge's* API — the thing every box depends on —
not the dashboard. The mitigation is that the cutover's proof is the
*existing* `edge-forward` L2 test unchanged in what it asserts (same
data path, same store-held-key equality, same `/128` bind): if the site
binary passes that, the operator/health surface is genuinely equivalent.

Strongest defense: the user explicitly chose to avoid a two-edge-binary
window, the duplication it would leave is real debt, and `alloc_machine`
already forces T6 before T4 (the panic), so the boot wiring was never
optional. Second-order objection: T3 refactors a component T10 will
delete. The defense is the same call already made for `Landing` — until
the poem surface is deleted, two divergent dashboards are worse than one
shared component. Third: this arc opens a debt it does not close —
after T7/T8, poem's `web.rs`, the `fortress-edge` binary, and the poem
deps are dead but still built and tested. T10 (delete them) must be the
next arc, not an indefinite deferral.
