# Proposal: Consolidate on axum + dioxus + utoipa (ADR-033)

## Premise

The website today is a Rust controlplane binary (poem + poem-openapi
+ momenta rsx + a vendored Tailwind *browser JIT* executed on every
page load) that carries landing copy, a markdown wiki, auth forms,
the machines dashboard, and the OpenAPI API in one tree. Three of
those layers are hand-invented tech (momenta rsx, vendored runtime
CSS compiler, poem routing). The debt engine: *change one word* =
recompile the edge binary; copy lives in Rust; three nonstandard
things (momenta + htmx + vendored runtime CSS) have to be reasoned
about together. Verified against upstream docs: dioxus 0.7
fullstack mounts SSR as an axum **fallback** (custom routes win),
and utoipa-axum 0.2 derives OpenAPI from `#[utoipa::path]`
handlers — so axum + dioxus + utoipa is one process, one router
shape, standard tooling.

## Alternatives considered

1. **Keep poem, build-time render `/docs` only.** Smallest diff,
   but leaves momenta + poem + vendored runtime CSS — the debt
   engine stays in the four stateful pages. Case against: postpones
   rather than removes.
2. **Adopt Astro/JS meta-framework for static + keep Rust API.**
   Two build systems, two styling paths, state moves into JS
   islands — abandons the "engine of state is 100% on the server"
   invariant this project deliberately keeps (Redis/WG/DNS are not
   render-time concerns).
3. **Dioxus replace momenta (chosen).** One rsx framework with a
   community, md at request time (or cached after first hit —
   both zero-external-origin compatible), utoipa for the API.
   Case against: the migration must move the *request layer* too
   (poem handlers → axum extractors, poem-openapi → utoipa), and
   the contract test tiers (spec gates, L2 `edge-forward`) are
   rebuilds, not edits.

## Acceptance criteria

- AC1: The site ships **zero runtime CSS compiler** — a static
  zine-token stylesheet serves both landing and app surfaces.
- AC2: `/` root render path is dioxus (SSR fallback); `/api/*`
  routes are axum+utoipa; `/install.sh` is embedded
  (`include_str!`) and route-served on the new stack.
- AC3: `/docs/:slug` renders real markdown files (folder as
  content, path-based routing, no per-page Rust).
- AC4: The merged edge binary (`edge-control-plane`) serves
  everything on `:8081` via the axum composition; poem is
  **deleted** (not coexisting) at the end.
- AC5: All L0 forwarder/unit tests + L1 flake checks + L2
  `edge-forward` PASS after the swap; `vmtest-e2e.sh` PASS before
  declaring the migration done.

## Task DAG (each task names its proof)

- T0: branch `axum-dioxus-migration` + this proposal. — proof: this
  file, committed.
- T1: scaffold `crates/site` (dioxus fullstack: `launch`/`serve`
  split, zine static CSS, `/install.sh`, `/docs/:slug` via
  dioxus-markdown, landing placeholder). — proof: crate tests PASS;
  poem tree untouched.
- T2: auth/machines pages on dioxus axum (register/login/machines),
  session cookie handlers re-extracted. — proof: web round-trip tests
  PASS against the new surface (side-by-side until cut).
- T3: control-plane API poem→axum+utoipa; spec-gate tripwires re-
  derived; merged edge binary wiring swapped to axum. — proof: L1
  checks + spec-gate tests PASS.
- T4: the QEMU vmtest/e2e harness exercises the full system. —
  proof: `scripts/vmtest-e2e.sh` PASS + `edge-forward` L2 PASS.
- T5: delete poem/momenta drift; vendored Tailwind runtime out. —
  proof: flake check all-pass + STATUS.md updated same commit.

## Task-now cut

This session: T0 + T1 (scaffold compiles, smoke test at L0),
STATUS.md updated in same commit. Poem application tier continues
to serve the public site until T2/T3.

## T2a cut (register + login + session round-trip, 2026-09-19)

Architecture decision: the dioxus site **embeds the ControlPlane**
(server-gated `fortress-controlplane` dep), not an HTTP call to
poem. Matches AC4's one-binary end state; reuses the account domain
methods; adds no poem API surface. Verified against dioxus 0.7.10
source: `#[server]` fn bodies are `#[cfg(feature = "server")]`-gated
(dioxus-fullstack-macro src/lib.rs:502/526), so the wasm tier never
compiles the controlplane dep; `Form<T>` is a supported input
encoding (dioxus-fullstack payloads/form.rs:3), and `FullstackContext`
exposes both request extraction and `add_response_header` for the
session cookie.

**UI ergonomics — no htmx replication.** The poem surface is
form-POST-then-server-rerenders; the dioxus surface uses fullstack
ergonomics instead: dioxus components hold form state (`use_signal`),
call `#[server]` fns that return typed outcomes (serde structs), and
the server fn sets the `fortress_account_session` HttpOnly cookie via
`FullstackContext::add_response_header` on success. No `<form
action>` round-trips, no partial-page re-render.

Cut contents:
- T2a1: site gains `fortress-controlplane` (server-gated) + serde.
- T2a2: boot wiring — site server main inits a forwarder-free
  ControlPlane against Redis (account methods are pure Redis+mailer;
  the site must NOT own the forwarder/wg0, that is the edge's job).
- T2a3: `#[server]` fns `signup`, `login`, `logout`, `current_session`
  reading the cookie from `headers: HeaderMap` and setting it on the
  response via `add_response_header`.
- T2a4: dioxus `RegisterPage`/`LoginPage` components + routes; the
  landing's `logged_in` flag wired to a `current_session` call.
- T2a5: L0 round-trip tests against the new surface (redis-gated),
  proving signup→verify→login→session→logout against real Redis.

Deferred to T2b: forgot/reset/verify/resend/verify-notice pages,
the machines dashboard + invites, `/a/:code` join page.

**T2a DONE (2026-09-20)** — all five tasks landed. Proof:
`cargo test -p fortress-site` = 9/9 incl. the redis-gated
`signup_verify_login_logout_fullstack_round_trip` driving the real
surface end-to-end (REDIS_URL=redis://127.0.0.1:6379); live-server
smoke (debug bundle, `--dummy`) showed signup→verify→login→logged-in
landing→logout→logged-out landing against :8082; `nix flake check`
PASS; `nix build .#siteBundle` PASS; wasm tier `cargo check` clean.
Deliberately did NOT build a `verify` page yet — only the server fn
(needed for the lifecycle round trip). Amended from the original
plan where reality bit: the server-fn endpoint paths are relative to
the `/api` prefix (dioxus concats prefix+route), and the `src` fileset
only sees git-tracked files (account.rs must be `git add`-ed before
the nix build sees it).

## The full transfer arc (T2b + T3, decided 2026-09-21)

Goal: the **edge site** (proletariat.tech) is served entirely by
`fortress-site`; poem's web + API surfaces are deleted. The box's
local :3000 config dashboard (crates/client) is **out of scope** —
it stays poem for now (operator decision).

Decisions locked this session:

- **Pages = dioxus server fns** (the T2a pattern, extended). Verified
  against dioxus 0.7.10 registry source: `#[server]` fns support path
  params (`{code}` / `:code`), GET/POST/PUT/DELETE/PATCH, JSON wire
  with the fn's arg names as keys, arbitrary `#[cfg(feature =
  "server")]` bodies (Redis/ControlPlane/anything), and mount on the
  same axum router as the pages via `register_server_functions()`.
- **The `/api/*` contract = plain axum + utoipa handlers**, NOT
  server fns. Reason: utoipa derives the spec from axum handler
  signatures; server fns hide their handlers, so `#[utoipa::path]` on
  a server fn would document the Rust signature (named args +
  `ServerFnError`) not the real wire shape (positional JSON body).
  Also checked: dioxus's *native* OpenAPI (`api_route`/`oapi_options`
  in the macro) is dead in 0.7.10 — the runtime crates have zero
  `aide` dep and never re-export `api_route`. So **utoipa is the
  swagger path**, and it requires real axum handlers for the API.
- **Keep `/api/docs` + `/api/openapi.json`** via utoipa-swagger-ui
  (operator surface today).
- **Topcoat (tokio-rs) considered and deferred**: 2 months old; and
  it is htmx-style, which is the form-POST ergonomics this migration
  is deliberately leaving. Revisit in ~1yr, not now.

The client-facing contract that must survive **byte-for-byte**
(`crates/client/src/pairing.rs` dials these):
`POST /api/invites/{code}/begin`, `GET /api/invites/{code}/poll`,
`GET /api/wireguard/pubkey`, `POST /api/device/register`. Plus the
operator + spec-gate + L2 `edge-forward` surfaces:
`/api/users/*`, `/api/wireguard/*` (AdminKey), health,
`/api/docs`, `/api/openapi.json`.

### T2b — remaining pages as server fns
- `forgot`, `reset`, `verify` page, `resend` + verify-notice,
  `machines` dashboard + invite approve/deny/revoke, `/a/:code` join,
  account delete.
- One redis-gated round-trip test each, mirroring T2a.

### T3 — the merged edge binary (site becomes the edge)
- **T3a**: `/api` on axum + utoipa in `crates/site` (new deps:
  `utoipa`, `utoipa-axum`, `utoipa-swagger-ui`; verify version for
  axum 0.8). Port `auth.rs` UsersApi + `pairing.rs` InvitesApi +
  WireguardApi + health.
- **T3b**: the site binary gains the **real forwarder + real
  WG/DNS clients**. Known gap: `crates/site/src/main.rs:21` uses
  `MockWgClient` + `MockDnsApiClient` unconditionally even in the
  non-dummy path — the site cannot allocate machines for real today.
  Also the site binds a hardcoded :8082; needs an addr flag.
- **T3c**: `--dummy` stays a debug-builds-only dev flag, mirroring
  the edge.

### Acceptance gates (what "done" means)
- `nix run .#dashboard-dev` runs **only the new stack**: the `edge`
  process is deleted from `nix/dev/process-compose.nix`, `site` is
  the single server (binds :8081 in dev to mirror prod), `redis` +
  `dashboard` (client config editor) stay.
- The edge systemConfig (`flake.nix` `fortressEdgePkg` →
  `systemConfigs.edge`) points at the **site bundle** instead of the
  poem `fortress` package; same systemd unit + Caddy :8081.
- `pairing.rs` enrollment works against the site binary (begin→poll→
  approve→device/register byte-compatible).
- Then delete poem: `web.rs`, `auth.rs`, poem deps, the
  `fortress-edge` binary. Box :3000 dashboard keeps poem for now.
- **Hydration proof is still open and gates everything**: a real
  browser must hydrate `.#siteBundle` and make the forms live
  (headless browsers hang in this env — operator runs this check).
- Per-surface ACs (the strongest-objection guard): each ported page
  has its own redis-gated round-trip test + a rendered-HTML assert,
  so a half-cut can't masquerade as done.

## Strongest objection

The machines dashboard is a *wired re-render+React-style* surface
today; dioxus owns re-render and hydration there, so a half-cut
(htmx still driving part of the page) would be indistinguishable
from done — "ha, it works" is a the failure this plan must guard
against by keeping the AC list per-surface and per-proof.
Secondary: dioxus 0.7 fullstack is young; a rot/deprecation risk
betrays the long-term investment — mitigated by keeping the md +
tokens architecture-independent (T1 works in both worlds).
Tertiary (new): the merged edge (T3b) must run the real forwarder +
WG/DNS, which the site has never done — the riskiest unknown in the
arc. Mitigation: land T3b as its own step with the `--dummy`
dev-loop as its proof, before the edge deploy.
