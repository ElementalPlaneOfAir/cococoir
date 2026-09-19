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

## Strongest objection

The machines dashboard is a *wired re-render+React-style* surface
today; dioxus owns re-render and hydration there, so a half-cut
(htmx still driving part of the page) would be indistinguishable
from done — "ha, it works" is a the failure this plan must guard
against by keeping the AC list per-surface and per-proof.
Secondary: dioxus 0.7 fullstack is young; a rot/deprecation risk
betrays the long-term investment — mitigated by keeping the md +
tokens architecture-independent (T1 works in both worlds).
