# Nix config parser — lossless round-trip for the dashboard config editor

Status: implemented + verified 2026-08-13 (L0 + L1 green). T1–T4 done.

Session 2026-08-13: user interview. Three decisions made:
- File shape: the dashboard edits a NixOS-module-style file (function
  header `{ config, lib, pkgs, ... }:`, `let ... in`, attrset body) like
  `nixosConfigurations/vmtest.nix`. The *known-field set* is a dashboard
  UI concern, decoupled from the file syntax so the config language can
  change without the parser breaking.
- Parser: the `rnix` crate (mature, lossless CST — what nixpkgs-fmt
  builds on). The learning is in *interpreting* a token/CST tree and
  splicing edits by source span, not in hand-writing a lexer (which was
  explicitly offered and rejected as not worth the months).
- Round-trip model: **lossless CST with source spans.** Unknown content
  survives byte-for-byte; only known-field spans get rewritten.

## Premise

The dashboard (`cococoir-client` embedded UI, `src/dashboard/`) will
eventually edit the customer's Nix config file: read it, let the user
change fields the dashboard knows about, write it back. The hard part is
the round-trip: a config file is full of things the dashboard does not
model (comments, other NixOS options, `let` bindings, imports, formatting),
and a naive "parse into my struct, re-emit my struct" destroys all of it.
The existing scaffold at `src/dashboard/nix_config_parser.rs` sketches the
target model (`CococoirConfig` with `hostname`, `root_domain`,
`services_enabled`, `users`, `extra_config`) but has no parser behind it.

This arc delivers that parser as a pure-Rust module, learning-grade
(span arithmetic, CST navigation, token interpretation) but production-shaped
(lossless, tested). No dashboard UI wiring yet — the parser is the
foundation the editor UI builds on later.

## Acceptance criteria

- [x] L0: `cargo test` passes. New tests cover: round-trip identity
      (parse→serialize with no edits is byte-identical, including a
      vmtest.nix-style fixture); known-field extraction from a
      vmtest-style file; lossless field replacement (only the target
      value's span changes, everything else byte-identical); missing
      known field reports cleanly. Maps to T1–T4.
      Verified 2026-08-13: `cargo test` 76/76 pass (15 parser tests new).
- [x] The parser rejects non-Nix / malformed Nix with a typed error and
      never panics on hostile input (empty string, unmatched braces,
      garbage tokens). Maps to T1, T2.
      Verified: `rejects_malformed_input_without_panicking` covers all
      hostile inputs.
- [x] L1: `nix flake check` passes — `rnix` builds under the flake's
      cargoLock and the existing checks (`doc-refs`, `contract-conformance`,
      `vmtest-wiring`, L0 crate tests) stay green. Maps to T1.
      Verified 2026-08-13: all 20 flake checks pass.
- [x] No dashboard UI, no NixOS-module wiring, no new customer-facing
      option in this arc. The parser is `pub` but nothing calls it from
      routes yet. Maps to the task DAG being parser-only.

## Smallest version

A `nix_config_parser` module (rnix-backed) that can, given a config file
string:
1. parse it into a lossless CST, failing with a typed `NixParseError`
   on malformed input;
2. navigate the CST to find a known field by attribute path
   (`cococoir.services.jellyfin.enable`), returning its value and its
   byte span;
3. replace that value in place, producing a new string where only the
   target span changed;
4. serialize with no edits = identical input (round-trip law).

The `CococoirConfig` struct from the scaffold becomes the *schema layer*:
it declares which attrpaths are "known" and reads/writes them. The
`extra_config` field is the *whole CST outside the known-field spans* —
it survives by construction, not by being copied into a String. This
replaces the scaffold's `extra_config: String` idea, which cannot survive
a round trip (see Alternatives).

## Alternatives considered

- **Hand-written lexer + recursive-descent parser** — case for: the
  full compiler-education experience, no dependency. Case against: Nix
  is a big grammar (string interpolation/antiquotes, `let...in`,
  `rec`, `inherit`, paths, function patterns, urls, operators); a
  correct lossless parser is months of work and the round-trip only
  needs CST *interpretation*, not CST *construction*. The user was
  offered this and rejected it. Winner: `rnix`.
- **`extra_config: String` copied out of the tree** — case for: simple
  struct, matches the scaffold. Case against: a String is a flat blob;
  it cannot preserve comments *between* known fields, it cannot preserve
  formatting, and re-inserting it loses position (does the extra config
  go before `hostname` or after? inside the `let` or in the body?). A
  config file is a *tree with positions*, so preservation must be
  positional. Winner: keep the CST + spans; `extra_config` becomes "all
  spans not covered by a known field", which round-trips by construction.
- **Full Nix re-format on write** (run the file through a formatter
  like nixfmt on save) — case for: always-canonical output. Case
  against: reformats the user's entire file on every dashboard save,
  producing noisy diffs and destroying intentional formatting. Winner:
  surgical span replacement.
- **Parse once at boot, serve a snapshot** — case for: trivial. Case
  against: the user edits the file, the dashboard must *re-read* it;
  "reflect changes on the next reboot" means the dashboard must read the
  current file, not a stale copy. Winner: parse on demand from the file
  path.

## Architecture decisions

- **No new ADR.** This is the foundation of the config-editor arc the
  htmx-dashboard proposal deferred ("parse-Nix → in-memory → regenerate
  → git commit → nixos-rebuild on Apply"). When the UI arc lands, it
  records an ADR. This proposal extends ADR-024 (Rust crate) and the
  htmx-dashboard proposal's deferred config-editor scope.
- **`rnix` 0.14 is the parser.** Lossless rowan CST (`Parse<T>` →
  `.ok()`/`.tree()`/`.errors()`), `TextRange` byte spans, `AstNode`
  trait for typed navigation (`ast::Root`, `ast::Lambda`, `ast::AttrSet`,
  `ast::Entry`, `ast::Inherit`, `ast::Str`, `ast::List`, `ast::Ident`,
  `ast::Literal`). The same machinery nixpkgs-fmt uses, so the
  round-trip law is trusted upstream.
- **Schema is separate from parser.** The parser is shape-agnostic: it
  walks the CST and finds attrpaths. The `CococoirConfig` schema decides
  *which* attrpaths are known. When the config language changes, only
  the schema's path list changes, not the parser. This is the
  "decouple UI fields from file syntax" requirement.
- **Known fields are addressed by attrpath**, not by regex or line
  number: `cococoir.services.<name>.enable`, `cococoir.baseDomain`,
  etc. Handles both dotted attrpaths (`a.b.c = v`) and nested attrsets
  (`a = { b = { c = v; }; }`), plus `inherit`, via CST navigation.

## Tasks

### T1: add `rnix` and a lossless parse→serialize round trip
**Depends on:** none
**Verification:** `NixConfigFile::parse(source) -> Result<NixConfigFile,
NixParseError>`; `to_string()` returns the exact input when no edits are
made; round-trip identity asserted on a vmtest.nix-style fixture (function
header + `let` + nested attrsets) and on empty/garbage input (typed error,
no panic). L0 + flake build.
**Files:** `nix/packages/cococoir/Cargo.toml`,
`nix/packages/cococoir/src/dashboard/nix_config_parser.rs`
- [x] DONE 2026-08-13. `rnix 0.14` + `rowan 0.16` added; `NixConfigFile`
      with `parse`/`to_source`; `rejects_malformed_input_without_panicking`
      passes on `""`, `"{"`, `"}{"`, `"cococoir = "`, garbage. Round-trip
      identity green.

### T2: attrpath navigation over the CST
**Depends on:** T1
**Verification:** `find_attrpath(&self, &["cococoir", "services",
"jellyfin", "enable"])` resolves dotted and nested forms, returns value
node + `TextRange`; `inherit` handled; missing path → `None`; a path that
lands mid-expression (not a value) → `None`, not a panic. L0.
**Files:** `nix/packages/cococoir/src/dashboard/nix_config_parser.rs`
- [x] DONE 2026-08-13. `find_attrpath` handles dotted keys
      (`services.radarr.enable = false;`), nested attrsets, `let ... in`,
      function headers, `inherit` (skipped → `None`), mid-expression
      descent → `None`. `attrset_keys` added for user enumeration.

### T3: known-field extraction into the schema
**Depends on:** T2
**Verification:** given the `CococoirConfig` schema (attrpath list),
extract a read-only snapshot of known fields (hostname, root_domain,
services_enabled, users) with their spans; unknown content is untouched.
Field values parsed from CST nodes: string literals (plain and
interpolated), booleans (`true`/`false`), string lists. L0.
**Files:** `nix/packages/cococoir/src/dashboard/nix_config_parser.rs`
- [x] DONE 2026-08-13. `ConfigSchema` (default paths match vmtest.nix
      shape) + `CococoirConfig::extract`. Strings, bools, string lists
      parsed; interpolated strings fall back to `NixValue::Other` (raw).
      SERVICE_LIST aligned to shipped services (dropped scaffold's
      vaultwarden — not a real cococoir service; PLAN lists jellyfin,
      cryptpad, radarr, sonarr, lidarr, prowlarr, dex).

### T4: in-place value replacement (the write path)
**Depends on:** T3
**Verification:** `set_attrpath(&mut self, path, "true")` replaces only
the value node's span; surrounding text (comments, indentation,
semicolons, the `=` sign, other bindings) is byte-identical; replacing a
string with a bool and vice versa works; after any single edit,
re-parsing the output round-trips (edit is idempotent and lossless).
Missing attrpath → `SetError::NotFound`, no insertion in this task
(insertion is the UI arc). L0.
**Files:** `nix/packages/cococoir/src/dashboard/nix_config_parser.rs`
- [x] DONE 2026-08-13. `set_attrpath` splices exactly the value span and
      validates the result re-parses before committing (failed edits leave
      the file untouched). `SetError::{NotFound, InvalidValue}`;
      `set_then_set_back_round_trips` proves idempotence.

## Strongest objection

The parser is a self-contained learning exercise that nothing calls yet,
and the config-editor UI (which would justify it) is explicitly deferred.
If the dashboard never grows a config editor, this module is dead code
that AGENTS.md would demand be deleted. Strongest defense: the htmx
proposal already committed to the config-editor arc; the parser is its
required foundation, and the round-trip law it establishes (only known
spans change, everything else survives) is the non-negotiable requirement
any later implementation must satisfy. Building it first, with tests,
de-risks the UI arc rather than preceding it into the void. Second-order
risk: `rnix`'s error tolerance — `.ok()` reports the *first* parse error,
but a file with one typo may still produce a partial tree; T1's contract
(fail on malformed input, never write a partial edit) must be enforced
before any edit path trusts the tree.
