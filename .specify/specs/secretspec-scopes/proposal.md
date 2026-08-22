# secretspec scopes for the edge provisioning scripts

## Premise

Today `secretspec.toml` is consumed only by the `cococoir-edge` Rust binary
(`declare_secrets!`, typed loader, `[profiles.default]`), resolved at runtime
from `/etc/cococoir/edge.env` on the box. The provisioning scripts
(`provision-edge.sh`) run on the operator's laptop and source their secrets
ad-hoc: the Hetzner token from `HCLOUD_TOKEN` / a file, the admin key generated
inside the script. They never touch secretspec.

The operator wants one `secretspec.toml` to serve *both* consumers, using
**scopes** to give each consumer only the subset it needs. Concurrently, the
provisioner currently generates + provisions WireGuard keypairs — but WG keys
are the application binary's job (the edge already self-generates its keypair
and serves the public half at `GET /pubkey`; signup returns it). That WG
provisioning is leftover cruft and must be deleted, including tofu reading WG
public keys.

"Token + admin key" are the provisioner's responsibility. WG is not.

## Decisions locked with the operator

- **scopes = real tool here, not dead weight.** The provisioning script has
  two resolution moments with genuinely different subsets:
  - `tofu apply` needs only the token (as `HCLOUD_TOKEN`).
  - writing `edge.env` needs token + admin key.
  Two scopes carve the shared `[profiles.provisioning]` profile:
  `[scopes.token]` = `[HETZNER_TOKEN]`, `[scopes.provision]` =
  `[HETZNER_TOKEN, ADMIN_KEY]`. This mirrors the scopes docs' canonical case
  ("an API and a worker share a profile, receive different credentials").
- **Separate profile, not shared default.** The edge binary's `declare_secrets!`
  reads the *whole* `[profiles.default]` and would gain a field for any secret
  added there → resolution fails on the box (not in `edge.env`). So provisioning
  secrets live in `[profiles.provisioning]`, keeping `[profiles.default]`
  byte-identical. The typed loader is untouched (compile-time rename/removal
  safety preserved) and the running edge cannot regress.
- **CLI, not SDK, for provisioning.** The provisioning scripts are bash; the
  embedded SDK only makes sense in a typed language. nixpkgs unstable (already
  the flake's locked input, rev `ec2d622d`, 2026-08-17) ships **secretspec
  0.19.0**, which has `export --profile/--scope/--format dotenv` and the
  read/write/generate `file` provider. No flake bump needed. The operator runs
  `nix run` (or the devshell) to get the CLI.
- **`ADMIN_KEY` is a generated, persisted secret.** Declared in
  `[profiles.provisioning]` with `type = "hex", generate = { bytes = 16 }`
  (32 hex chars, matching today's `openssl rand -hex 16`), routed to the
  `file` provider so the value persists across re-provisions — the box's
  `ADMIN_KEY_HASH` stays stable. Generation triggers only when missing;
  existing values never overwritten. This replaces the script's
  `openssl rand` + `.secrets/admin.key` logic.
- **`HETZNER_TOKEN` is a read secret** (operator supplies it once via
  `secretspec set`), routed to the `file` provider too, so both provisioning
  scopes resolve from the same store.
- **Provisioning store** = a `file:` root at `remote-infra/.secrets/`
  (already gitignored). `secretspec export -P provisioning -S <scope>` reads
  `{project}/{profile}/{key}` from there. **Root-relative URI
  (`file:./remote-infra/.secrets`), resolved against the `-f` path**, not
  absolute: secretspec 0.19 collapses `..` in relative roots (tested), and
  the toml is reached through the repo-root symlink, so `./remote-infra/...`
  resolves to the operator store on any checkout. The provider root is
  anchored to the `-f` argument's directory, not cwd (tested from
  `remote-infra/` with `-f ../secretspec.toml`).
- **Delete all WG key provisioning.** `gen-wg-keys.sh`, the `wg` step +
  `ADMIN_KEY`/WG wiring in `provision-edge.sh`, the `wg_public_keys` output,
  the `edge_wg_pub`/`customer_wg_pub` locals in `main.tf`, and the WG render
  in `render.tf` / `example123.nix.tftpl`. The customer box gets the edge's
  WG public key from the `/signup` flow or `GET /pubkey`, not from a static
  tofu render. The edge box keeps its throwaway-key `wg0.conf` bootstrap (the
  binary owns the real key at runtime — that's not provisioning cruft).
- **One toml, real file in the crate, symlinked at repo root.** The real
  `secretspec.toml` lives at `packages/cococoir/secretspec.toml` (the crate
  moved from `nix/packages/cococoir/` — see T0); the repo root has a symlink
  `secretspec.toml -> packages/cococoir/secretspec.toml`. The real file must
  stay in the crate: `declare_secrets!` reads it at compile time from
  `CARGO_MANIFEST_DIR`, and in the Nix build that is a **store path** — a
  symlink there resolves to `/nix/...` (dangling, tested), while a real file
  is copied in by `cleanSourceWith` and reads correctly (tested). The root
  symlink gives the provisioning CLI a stable `-f` anchor so
  `file:./remote-infra/.secrets` resolves against the repo root. The box
  deploys the crate's real toml as today. The typed loader only materializes
  `[profiles.default]`, so the extra `[profiles.provisioning]` +
  `[scopes.*]` blocks are inert to the edge binary. Single source of truth
  for the whole secret inventory.

## Acceptance criteria

- [x] `provision-edge.sh` resolves the token via
      `secretspec export -P provisioning -S token` and token+admin via
      `-S provision`, instead of reading `HCLOUD_TOKEN`/a file directly.
      (Verified: script uses both scopes with `--format shell`; see T2.)
- [x] `edge.env`'s `ADMIN_KEY_HASH` equals `sha256(ADMIN_KEY)` where
      `ADMIN_KEY` is the generated persisted secret — stable across a
      second run (re-provision). (Verified: two exports → identical hash;
      the script hashes the exact 32-char hex, no trailing newline.)
- [x] `gen-wg-keys.sh` is deleted; `provision-edge.sh` has no `wg` step and
      never touches `.secrets/wg/`. (Verified: `tofu validate` green;
      `main.tf` has no `edge_wg_pub`/`customer_wg_pub` locals, no
      `wg_public_keys` output; the stale `.secrets/wg/` dir removed.)
- [x] `[profiles.default]` is byte-identical; `declare_secrets!` still
      resolves exactly the five runtime secrets. (Verified: 145 `cargo
      test`s green incl. `secret::tests::*`; the typed struct field set
      is unchanged.)
- [x] `nix flake check` green (edge systemConfig builds; only the
      pre-existing `example123` placeholder fails). `cargo test` green.
- [x] `docs/STATUS.md` updated in the same commit.

## Smallest version

- The provisioning profile + two scopes + CLI wiring in `provision-edge.sh`.
- Delete the WG provisioning cruft (script, tofu locals/output/render).
- Everything else (the `/signup` customer-side wiring of the edge pubkey, a
  real secret store swap) stays deferred.

## Alternatives considered

- **Add provisioning secrets to `[profiles.default]` + one shared scope.**
  Case for: single profile, simplest diff. Case against: the typed loader
  reads the whole default profile and would gain fields for `HETZNER_TOKEN` /
  `ADMIN_KEY`, breaking resolution on the box (they're not in `edge.env`).
  Rejected.
- **Profiles only, no scopes.** Case for: fewest moving parts. Case against:
  the operator explicitly asked for scopes, and the tofu-vs-edge.env split is
  a genuine scopes case (two consumers, shared profile, different subsets).
  Adopted scopes.
- **SDK in a Rust helper app for provisioning.** Case for: pins version in
  the lockfile like the edge. Case against: provisioning is bash; the CLI in
  the already-locked nixpkgs is simpler and the operator runs bash anyway.
  Rejected per operator decision.
- **Keep WG keys provisioned by the provisioner.** Case for: no change to the
  customer render. Case against: it's duplicate of what the edge binary
  already owns (self-generates + `GET /pubkey`), and the operator confirmed
  it's leftover cruft. Rejected.

## Architecture decisions

No new ADR. Extends the admin-api-auth secretspec seam (ADR-in-proposal) with
scopes + a provisioning profile; reuses the existing `[profiles.default]`
typed-loader contract unchanged. The `file` provider (0.19+) gives the
provisioning profile a writable local store for the generated, persisted
`ADMIN_KEY` — the honest tool for "generate once, reuse forever." Scopes carve
the profile per consumer per the secretspec scopes spec.

## Tasks

### T0: Move the crate to `packages/cococoir/` + establish the toml layout
**Depends on:** none
**Verification:** `nix flake check` (edge systemConfig builds); `cargo test`.
**Files:** repo-wide (flake, devenv, doc-refs, scripts, comments)
- [x] DONE 2026-08-22 (operator moved `nix/packages/cococoir` →
      `packages/cococoir` + committed root toml; agent corrected the
      symlink to real-file-in-crate + root-symlink, removed the orphaned
      `nix/packages/cococoir/secretspec.toml`, fixed stale paths, added
      `apps.secretspec` (devenv's 0.18 lacked the `file` backend), removed
      `secretspec` from devenv packages. Edge systemConfig **builds** —
      proves `declare_secrets!` resolves the real toml in the store.)

### T1: Add `[profiles.provisioning]` + `[scopes.*]` + provider to secretspec.toml
**Depends on:** T0
**Verification:** `secretspec export -P provisioning -S token` and `-S provision`
resolve the right subsets from a scratch file store; `[profiles.default]`
unchanged.
**Files:** `packages/cococoir/secretspec.toml`
- [x] DONE 2026-08-22 — scopes resolve correct subsets from a scratch store;
      ADMIN_KEY generates once and persists stably; `[profiles.default]`
      byte-identical. Note: every CLI call needs `--reason` (require_reason
      policy) — provision-edge.sh must pass it.

### T2: `provision-edge.sh` — resolve via CLI, drop WG + admin-key cruft
**Depends on:** T1
**Verification:** script exports token via `-S token` for tofu and writes
`edge.env` (DNS_TOKEN, ADMIN_KEY_HASH) via `-S provision`; no `wg` step, no
`.secrets/wg/`, no `openssl rand` admin-key generation; `ADMIN_KEY` persists
across runs.
**Files:** `remote-infra/scripts/provision-edge.sh`
- [x] DONE 2026-08-22 — resolves both scopes via `nix run .#secretspec`
      (`--format shell`, eval'd), `HCLOUD_TOKEN` from the token scope, writes
      edge.env from the provision scope. Hash computed on exact bytes
      (`printf '%s'`) — the old `sha256sum` of a newline-terminated file
      would have baked the newline into the hash and rejected every key.

### T3: Delete WG provisioning from tofu (main/render/outputs/template)
**Depends on:** none
**Verification:** `tofu validate` green; `main.tf` has no `edge_wg_pub` /
`customer_wg_pub` locals; no `wg_public_keys` output; `example123.nix.tftpl`
has no `edge_wg_pub` reference; `gen-wg-keys.sh` deleted.
**Files:** `remote-infra/tofu/main.tf`, `remote-infra/tofu/render.tf`,
`remote-infra/tofu/outputs.tf`, `remote-infra/tofu/templates/example123.nix.tftpl`,
`remote-infra/scripts/gen-wg-keys.sh` (delete)
- [x] DONE 2026-08-22 — `tofu validate` green; WG locals/output deleted;
      template + rendered `example123.nix` wg0 peer emptied (edge pubkey is a
      runtime `/pubkey`/signup value, deferred); `gen-wg-keys.sh` deleted;
      stale `.secrets/wg/` dir + README/variables.tf references cleaned.

### T4: Verify — L0, flake, tofu, STATUS.md
**Depends on:** T1, T2, T3
**Verification:** `cargo test` green (`secret::tests::*`); `nix flake check`
(edge systemConfig evals); `tofu validate`; double-run provision shows stable
`ADMIN_KEY_HASH`; `docs/STATUS.md` updated.
**Files:** `docs/STATUS.md`
- [x] DONE 2026-08-22 — 145 cargo tests green; `nix flake check` green except
      the pre-existing `example123` placeholder; `tofu validate` green;
      two exports → identical ADMIN_KEY/HASH; STATUS.md updated.

## Strongest objection

The scopes carve a shared provisioning profile, but the two consumers
(tofu-only-token vs token+admin) are both *in one script* — so a scope that
"keeps tofu from seeing the admin key" protects nothing real: the same bash
process that runs `tofu apply` writes `edge.env` seconds later. The
token/provision split is documentation, not an authorization boundary. If a
later refactor splits provisioning into separate processes, this earns its
keep; today it is structural neatness. The honest justification is the
operator's explicit request + the forward seam, not a security property. A
second objection: routing provisioning through a `file:` store in
`remote-infra/.secrets` is plaintext at rest — no better than the current
`~/.secrets/HETZNER_API_KEY` file — so the migration buys a unified inventory
and stable admin key, not real secret storage; that's the acknowledged
trade-off (the seam is the point; the store swap is a provider-URI change).