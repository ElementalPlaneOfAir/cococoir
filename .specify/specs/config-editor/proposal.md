# Config editor — dashboard edits a bare-attrset `dashboard.nix` on disk

Status: proposal (not yet implemented).

Session 2026-08-13: user interview. Decisions made:
- The editable surface is an explicit **`dashboard.nix`** — a bare-attrset
  NixOS module holding every customer-tunable field. The machine config
  imports it. Long-tail needs (`pkgs`, custom modules) stay in the machine
  config's own `imports`, so the editable file never needs a function header.
- Save = **write the file to disk only.** No apply, no `nixos-rebuild`,
  no git commit in this arc. git-commit-on-save and diff preview are an
  optional later feature.
- The editor runs **locally now** (`nix run .#dashboard-dev` against the
  repo's `dashboard.nix`), not as a NixOS module service yet.
- Config path comes from an env var (`COCOCOIR_CONFIG_PATH`).
- vmtest.nix **refactors to import `dashboard.nix`** so the bare-attrset
  shape is proven by a real boot, not just by eval.

## Premise

The v2 dashboard needs a configuration environment: read a Nix config file
from disk, render the fields it knows, let the customer edit them, write
the file back — no apply step. STATUS.md has this queued as the "config
editor UI arc"; the lossless parser (`nix_config_parser.rs`) is built and
verified but nothing calls it from a route yet. This arc wires it into the
dashboard and defines the file it edits.

The file shape is the design center. A NixOS module can be a bare attrset
and still `imports` function modules that get `pkgs` — so the customer's
editable file is just `{ ... }` (no header, no `let`, no `pkgs`), and the
machine config composes it. The parser's `ConfigSchema::default()` paths
already match that shape exactly (`networking.hostName`,
`cococoir.baseDomain`, `cococoir.services.<name>.enable`,
`users.users.<name>`), so the editor is schema-driven with zero parser
changes.

Deliberately out of scope:
- **Apply.** No `nixos-rebuild`, no git. The file changes on disk; the
  customer applies it however they already do.
- **Binding insertion.** The parser replaces existing values only. A field
  the customer wants but that isn't in the file yet stays a manual edit —
  the UI must say so, not fake it.
- **Observability spine** (probes/journald/consent, htmx-dashboard T3–T7).
  Separate arc, still deferred. The standalone `bin/dashboard.rs` is the
  editor's host; the `cococoir-client` embedding is untouched.
- **`public` / `tls` / storage as editable fields.** Schema expansion, later.

## Acceptance criteria

- [ ] L0: `cargo test` passes. New tests cover: value→Nix-source
      serialization (bool/str/strlist) round-trips through `set_attrpath`;
      the editor route renders a fixture file's known fields; `POST` saves
      the file to disk with only the edited spans changed; a failed edit
      (invalid value, missing path) leaves the file byte-identical. Maps to
      T4, T5.
- [ ] L1: `nix flake check` passes — `vmtest-wiring` gains assertions that
      vmtest renders with `dashboard.nix`'s declared service enables
      present (all six), proving the extraction didn't drop a service. Maps
      to T1, T2.
- [ ] L2: `scripts/vmtest-e2e.sh` outcome is **unchanged** by the
      extraction — the e2e stays where the P0 (jellarr) re-verification
      left it, and the dashboard.nix refactor is transparent to boot. Plus a
      manual proof: `nix run .#dashboard-dev` against the repo's
      `dashboard.nix`, edit + save, `git diff` shows only the changed spans.
      Maps to T1, T6.
- [ ] The config path is read from `COCOCOIR_CONFIG_PATH` (dev default:
      the repo's `nixosConfigurations/dashboard.nix`); a missing/unparseable
      file fails the editor with a clear message, never a panic. Maps to T3.
- [ ] Save is all-or-nothing: every edit in the form applies to one
      candidate file, re-parse validates, only then does an atomic
      write-then-rename hit disk. A single bad field blocks the whole save
      with a named error. Maps to T4.

## Smallest version

The dashboard's index page becomes the config editor. It reads
`dashboard.nix` on demand, renders hostname, baseDomain, six service
toggles, and the users' groups, and a Save button writes the file back
(all-or-nothing, atomic). The demo hello/counter content is replaced; the
`/hello`, `/update`, `/session*` endpoints and their tests stay until a
cleanup task. Nothing else.

## Alternatives considered

- **Keep editing vmtest.nix (a function module) in place** — case for: no
  new file, parser already handles function headers. Case against: the
  customer file stays scary (header, `let`, imports, VM harness), the
  dashboard's "surface" is undefined, and the 50-line customer config is a
  fiction. Winner: extract `dashboard.nix`.
- **A custom non-NixOS structure (`{ hostname, services = [...] }`) with a
  Nix module translating it to real options** — case for: no syntax
  leakage into the editable file. Case against: a whole translation layer
  to maintain, the factory contract (ADR-020) already owns the option
  tree, and the parser's schema already matches NixOS paths. Rejected: the
  translation layer is the exact duplication the factory exists to avoid.
- **git commit + diff preview on save** — case for: rollback, confidence.
  Case against: couples the dashboard to a git repo being present; the
  user deferred it. Rejected for this arc, documented as optional later.
- **`public` as an editable toggle now** — case for: it's a real
  customer-facing contract option. Case against: schema fields only, first
  cut; the editor must stay small to prove the save path. Deferred.

## Architecture decisions

- **No new ADR yet.** This extends ADR-020 (the factory owns the option
  tree — `dashboard.nix` is just a customer-written module importing it)
  and the nix-config-parser proposal. An ADR lands when the editor ships
  as a NixOS module service.
- **`dashboard.nix` is a bare-attrset NixOS module** at
  `nixosConfigurations/dashboard.nix`, imported by the machine config.
  `pkgs` never appears in it; the long tail lives in the machine config's
  `imports` (a bare attrset can `imports` function modules). This is the
  layer split: customer file = tunable fields, machine config = wiring +
  escape hatch.
- **Schema-driven editor.** `ConfigSchema` paths are the only thing the
  UI renders; value→source serialization (bool/str/strlist) lives in the
  schema layer next to the parser, so the config language stays one file.
- **Read on demand, write all-or-nothing.** Every page load re-parses the
  file from disk (the parser proposal's "parse on demand" decision). Every
  save applies all form edits to one candidate, validates, then writes via
  temp-file + rename.
- **The editor is the index page.** Landing on the dashboard is landing on
  the config editor. The demo routes are removed in a cleanup task, not
  left as dead weight.

## Tasks

### T1: extract `dashboard.nix` from vmtest.nix
- [x] DONE 2026-08-13. `nixosConfigurations/dashboard.nix` created (bare
      attrset: baseDomain, hostName, six service enables). vmtest.nix adds
      `imports = [ ./dashboard.nix ]` and keeps tls/storage/qemu/dex/
      users.root + the per-service `public` fields. `nix flake check` all
      green; rendered config eval shows all 7 services enabled + hostname
      intact (merge across files works).
**Depends on:** none
**Verification:** `nix flake check` green — the six service enables render
into `vmtestConfig` via the import, and the existing OIDC wiring assertions
still pass against the extracted shape (they depend on the enables
surviving). L1.
**Files:** `nixosConfigurations/dashboard.nix` (new),
`nixosConfigurations/vmtest.nix`

Move `cococoir.baseDomain`, `networking.hostName`, and the six
`cococoir.services.<name>.enable` declarations into `dashboard.nix` as a
bare attrset. vmtest.nix adds `imports = [ ./dashboard.nix ]` and keeps
the harness fields (`public`, tls, storage devices, qemu, dex settings,
users.users.root — those are infra/harness, not customer-tunable in this
cut). The module system merges across files, so the split is
transparent to the rendered config.

### T2: vmtest-wiring tripwire for the extraction
- [x] DONE 2026-08-13. `dashboardServices` + `dashboardServiceEnabled`
      assertions added; `nix flake check` green; negative test confirmed
      the assert fires when a service enable goes false.
**Depends on:** T1
**Files:** `nix/tests/vmtest-wiring/default.nix`

Add asserts that each of the six service enables in the rendered
`vmtestConfig.cococoir.services` is `true`, with messages naming
`dashboard.nix` as the source. This is the tripwire (constitution §7)
for the cross-file extraction: a silent drop now fails the build.

### T3: config path wiring in the dashboard binary
- [x] DONE 2026-08-13. `ConfigPath::resolve()` reads `COCOCOIR_CONFIG_PATH`
      (fallback repo-relative dashboard.nix); `read_config` returns
      `ConfigReadError::{NotFound,Io,Parse}`; path threaded through `app`
      as poem Data; process-compose passes the env var (repo-root path,
      accounting for the crate-relative cwd). `cargo test` 80/80,
      `nix flake check` green.
**Depends on:** none
**Verification:** `COCOCOIR_CONFIG_PATH` is read once; missing → a clear
editor error page, unparseable file → parse error surfaced in the UI, no
panic. Dev default points at `nixosConfigurations/dashboard.nix`. L0.
**Files:** `nix/packages/cococoir/src/bin/dashboard.rs`,
`nix/packages/cococoir/src/dashboard/mod.rs`,
`nix/dev/process-compose.nix`

The binary resolves the path from the env var (fallback: repo-relative
`nixosConfigurations/dashboard.nix`), and the editor routes hold it in
poem app state. process-compose passes `COCOCOIR_CONFIG_PATH` for the dev
loop.

### T4: value→source serialization + atomic save
- [x] DONE 2026-08-13. `NixValue::to_source()` (bool/str/strlist, Nix
      string escaping) in the parser file; `ConfigEdit` + `save_config`
      (all-or-nothing: every edit → one candidate → re-validate →
      temp-file + rename) + `write_atomic` + `SaveError` in mod.rs.
      `cargo test` 88/88 (8 new: 5 serialization round-trips, 3 save
      path incl. byte-identical-on-failure).
**Depends on:** T3
**Verification:** a new `write` layer in the schema file serializes
`NixValue` (bool/str/strlist) to Nix source that `set_attrpath` accepts;
round-trip tests prove serialize→splice→reparse is lossless. Save applies
all form edits to one candidate `NixConfigFile`, re-validates, and writes
via temp-file + rename only on full success; any failure leaves the file
byte-identical. L0.
**Files:** `nix/packages/cococoir/src/dashboard/nix_config_parser.rs`,
`nix/packages/cococoir/src/dashboard/mod.rs`

### T5a: parser `attrset_keys` under a dotted prefix (T5 blocker)
- [x] DONE 2026-08-13. `collect_child_keys` walks each entry's attrpath,
      pushing the segment at `path.len()` for dotted keys that extend past
      the target, recursing on nested/prefix matches; returns `None` when
      absent. Tests: `attrset_keys_handles_dotted_prefixes`,
      `extract_reads_groups_from_dotted_user_keys`.
**Depends on:** T4
**Verification:** `attrset_keys(&["users","users"])` returns `["nicole"]`
for `users.users.nicole = { groups = [...] };` (dotted), for
`users.users = { nicole = {...}; };` (nested), and `None` when the path is
absent. `find_attrpath` unchanged. `cargo test` green. L0.
**Files:** `nix/packages/cococoir/src/dashboard/nix_config_parser.rs`

The editor's user listing exposed a silent gap: `attrset_keys` matched
entries only by exact attrpath name count, so a dotted key
(`users.users.nicole = ...`) was invisible when enumerating under the
`users.users` prefix — the dashboard would render an empty Users panel
with no hint. Fix: enumerate direct children by walking each entry's
attrpath, taking the segment at `path.len()` when a dotted key extends
past the target path, recursing on prefix matches otherwise.

### T5: editor routes + HTMX UI
- [x] DONE 2026-08-13. Editor is the index route (GET renders known
      fields, POST applies + flashes "Saved."/error); `build_edits` skips
      undeclared fields; components render hostname/baseDomain/services/
      users with read-only states for undeclared fields; missing file →
      error banner, never a panic. `cargo test` 96/96. **The users panel
      exposed a parser gap (dotted prefixes) — fixed in T5a.**
**Depends on:** T4, T5a
**Verification:** `GET /` renders the editor (hostname + baseDomain text
inputs, six toggle switches, users' groups, Save button, status flash);
`POST /` applies edits and re-renders with "saved" or the named error.
Route tests cover render, save, and the no-fields-found empty state. L0.
**Files:** `nix/packages/cococoir/src/dashboard/mod.rs`,
`nix/packages/cococoir/src/dashboard/components.rs`

The editor is the index route, behind the existing auth gate. Users with
no editable groups render read-only; services with no `enable` binding
in the file render as "not declared — add manually" (no insertion).

### T6: manual + e2e proof
- [x] DONE 2026-08-13. Manual smoke test: built the dashboard binary,
      logged in (303 gate), rendered the real `dashboard.nix` (hostname/
      baseDomain/6 toggles present), POST-ed edits, verified on disk via
      `git diff --no-index` that only the edited spans changed (hostName
      `vmtest`→`smoke2`, baseDomain) and all comments/other bindings
      survived byte-for-byte. E2e: extraction is boot-transparent — all
      services active, health 200s, SSO JWT works; the only gate
      failures are the pre-existing jellarr P0. The e2e hang on the
      `/api/config` check became T7.
**Depends on:** T1, T5
**Verification:** `nix run .#dashboard-dev` against the repo's
`dashboard.nix`: edit + save, `git diff` shows only the changed spans.
`scripts/vmtest-e2e.sh` outcome unchanged by the extraction (still at the
P0 re-verification point). L2 + manual.
**Files:** none (verification only)

### T7: bootstrap `/api/config` curl timeout (e2e robustness)
- [x] DONE 2026-08-13. `curl --max-time 30` on the `/api/config` probe.
      **Surfaced two latent gate bugs the tripwire caught:** (1) the
      curl's result pipe died under `set -euo pipefail` when empty (added
      `|| true`); (2) the grep pattern `"password":[0-9]` never matched
      the served `"password": 1` (space), so the check could never pass.
      Both fixed. E2e now reports `cryptpad sso.password: optional (1)`
      PASS; the only remaining failures are the known jellarr P0
      (inactive / pipeline timeout) — unchanged from the pre-extraction
      gate.
**Depends on:** none
**Verification:** `vmtest-bootstrap.sh` no longer hangs forever on a slow
cryptpad `/api/config`: the curl gains `--max-time` and a `fail` that names
the missing field; the e2e exits with a clean diagnostic instead of a
silent hang. Manual: run the e2e, confirm it reaches and reports the
cryptpad sso.password line (pass or fail, not hang). L2.
**Files:** `scripts/vmtest-bootstrap.sh`

The e2e gate hung indefinitely at the CryptPad encryption-password check
because `curl -sk https://cryptpad.vmtest.local/api/config` has no
`--max-time`: on a fresh boot the first request can be slow, and a missing
response hangs the whole gate with no diagnostic. Silent hangs are the
worst failure mode for a gate — the fix is a loud fail with a named field.

## Strongest objection

This arc wires an editor into a *bare attrset* file, but the moment a real
customer needs `pkgs` or a custom module, the answer is "edit the machine
config by hand" — which is exactly the manual-Nix experience the product
exists to avoid. A non-technical customer landing on `dashboard.nix` will
hit the "not declared — add manually" state and be stuck. Strongest
defense: the 90% case (toggle the catalog services, set hostname/domain,
manage users) needs zero `pkgs`, and the extraction is the honest
definition of the customer surface. When the editor ships as a real NixOS
module service, the escape-hatch option (e.g. `cococoir.extraImports`)
can be added deliberately, gated on the same schema — but shipping it
before there's a customer who needs it would be weight on the airplane.
Second-order risk: the vmtest refactor touches the v2 gate while it's
already red on P0; the mitigation is that the extraction is mechanical,
L1-verified, and the e2e outcome is asserted *unchanged*, not improved.
