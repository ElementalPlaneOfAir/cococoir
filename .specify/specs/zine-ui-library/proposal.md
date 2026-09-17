# Zine UI library — one design system for every Fortress surface

## Premise

Why: three UI surfaces (controlplane pages in
`crates/controlplane/src/controlplane/web.rs`, the client local dashboard
in `crates/client/src/dashboard/`) each carry their own copy of the
document shell and Tailwind/daisyUI CDN tags, and only the landing has
the new zine identity. The rest is stock dark daisyUI. Style drift is
already visible; every new surface copy-pastes the shell again.

Why now: the local dashboard runs **on the box**, which may have no
internet — the CDN dependency is a latent breakage, not just debt. And
the landing's restyle proved the design language works; the next surface
built without the library hardcodes the wrong look.

If we don't build it: every new page picks a shell by copy-paste, the
zine identity fragments per surface, and the CDN dependency survives into
production traffic. No P0 is blocked by this, but the cost compounds
linearly with each new screen.

## Acceptance criteria

- [ ] A `crates/web-ui` crate owns the design tokens (palette/type/
      texture CSS), the document shells, and the shared momenta
      components; both `fortress-controlplane` and `fortress-client`
      consume it, and no page-level `data_theme`/CDN tags remain in
      either crate. *(L0: workspace tests green; grep: zero
      `cdn.jsdelivr` occurrences in `crates/`)**
- [ ] Tailwind is kept for styling but compiled locally: the
      `@tailwindcss/browser` script is vendored into the binaries
      (`include_str!`), pinned to a version, and served from the same
      binary that serves the page — nothing loads from a third-party
      origin at runtime. *(L0 test: rendered landing + dashboard HTML
      contain no external `http(s)` asset URLs)**
- [ ] daisyUI is gone: no `daisyui` references and no daisyUI class
      usage (`btn`, `card`, `badge`, `alert`, `input input-bordered`,
      `label-text`, …) in shipped page HTML. *(L0: grep over rendered
      test fixtures)**
- [ ] Intensity dial exists and is enforced by the shell, not by each
      page: `ShellVariant::Loud` (grain, halftone, ticker, torn edges —
      landing only) vs `ShellVariant::App` (same tokens, no marquee, no
      grain on data-dense surfaces, no rotated cards). *(L0: a test
      renders both variants and asserts the loud-only classes
      (`ticker`, `torn`, `halftone`) are absent from App output)*
- [ ] Status/badge language uses the stamp component on the machines
      dashboard (ACTIVE / PENDING / REVOKED machine states render as
      stamps). *(L0: existing machines-dashboard test extended to assert
      the stamp class on status text)*
- [ ] The landing keeps passing its existing content tests (64
      controlplane tests green) and visually matches the approved
      screenshots `/tmp/opencode/zine-{desktop,mobile}.png` (manual:
      re-render + screenshot review after migration).
- [ ] All auth and dashboard flows still pass their existing tests in
      both crates.

## Smallest version

T1–T3 only: the library exists, the landing and controlplane pages are
migrated, CDN/daisyUI gone from controlplane output, client dashboard
migrated. Everything else (dark "night zine" variant, prebuilt-Tailwind
swap, animation polish) is explicitly deferred.

## Alternatives considered

- **Keep daisyUI everywhere, restyle via theme overrides** — case for:
  smallest diff; case against: we'd fight daisyUI's rounded/soft
  aesthetic in CSS overrides forever, and it keeps ~1.1MB of unused
  component CSS on every page load.
- **Tailwind CLI build step (prebuilt CSS)** — case for: smallest
  runtime payload, no FOUC; case against: adds a Node/standalone-binary
  build step to a Rust/nix repo, and a silent-failure seam (new class
  used, rebuild forgotten → unstyled page found visually). The class
  names don't change when we later swap compilers, so this is deferrable
  without rework.
- **Per-crate CSS copies with no shared crate** — case for: zero
  refactor; case against: this is the status quo plus one more copy;
  guarantees drift.
- **Why the winner wins**: shared crate + vendored runtime build keeps
  the Tailwind ergonomics the user explicitly wants, deletes the
  third-party runtime dependency and the daisyUI weight, and puts every
  style decision in exactly one place (constitution #5, #14).

## Architecture decisions

- No new ADR needed; consistent with PLAN.md's existing
  momenta-for-server-rendered-UI decision and the htmx-only-for-dashboard
  decision (landing stays static; the library adds no JS beyond the
  vendored Tailwind runtime).
- The vendored Tailwind browser build is an accepted interim: FOUC on
  slow connections and ~280KB payload are known, deliberate costs.
  Swap-to-prebuilt is a mechanical later change because class names are
  the stable interface.
- Constitution #6 applies to the library: components assert on
  programmer errors (e.g. shell variant must be total, stamp text must
  be non-empty, href must not be empty on buttons).

## Tasks

### T1: web-ui crate — tokens, vendored Tailwind, shells, core components
**Depends on:** none
**Verification:** `cargo build -p web-ui`; unit test renders both shell
variants and asserts loud-only classes absent in App
**Files:** `crates/web-ui/{Cargo.toml,src/lib.rs,assets/tailwind-browser.js}`

### T2: landing migration
**Depends on:** T1
**Verification:** `cargo test -p fortress-controlplane --lib` (64 green);
screenshot re-render matches approved zine screenshots
**Files:** `crates/controlplane/src/controlplane/web.rs` (landing
section), `crates/controlplane/Cargo.toml`

### T3: controlplane auth pages + machines dashboard migration
**Depends on:** T1
**Verification:** existing auth/session/dashboard tests green; no CDN
URLs or daisyUI classes in rendered pages (grep test)
**Files:** `crates/controlplane/src/controlplane/web.rs` (non-landing
pages)

### T4: client local dashboard migration
**Depends on:** T1
**Verification:** `cargo test -p fortress-client` green (existing
`data-theme` assertions updated to the new shell)
**Files:** `crates/client/src/dashboard/components.rs`,
`crates/client/src/dashboard/mod.rs`, `crates/client/Cargo.toml`

### T5: tripwire — no external asset origins in rendered pages
**Depends on:** T2, T3, T4
**Verification:** shared test (or per-crate tests) asserting rendered
HTML of every page contains no `cdn.jsdelivr` / external stylesheet or
script URLs
**Files:** `crates/controlplane/src/controlplane/web.rs` (tests module),
`crates/client/src/dashboard/mod.rs` (tests module)

## Strongest objection

The visual identity is one session old and the user is still prototyping;
a library hardens today's taste into shared API before it has survived
contact with more surfaces. If the aesthetic shifts (e.g. toward
predominantly red, or a display typeface gets vendored), we churn the
library instead of one file. Mitigation: tokens are the only "API" the
surfaces depend on for look-and-feel; component markup is intentionally
thin (stamps/cards/buttons are ~10 lines each), so a palette or
typography shift is a token edit, not a migration. The objection stands:
if T2–T4 reveal the aesthetic still moving, stop and restyle before
migrating the client dashboard.
