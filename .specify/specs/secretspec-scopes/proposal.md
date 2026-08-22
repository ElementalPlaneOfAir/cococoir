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
  `{project}/{profile}/{key}` from there. Absolute root in the provider URI —
  the toml sits at `nix/packages/cococoir/`, far from the operator store, so
  relative roots would be fragile.
- **Delete all WG key provisioning.** `gen-wg-keys.sh`, the `wg` step +
  `ADMIN_KEY`/WG wiring in `provision-edge.sh`, the `wg_public_keys` output,
  the `edge_wg_pub`/`customer_wg_pub` locals in `main.tf`, and the WG render
  in `render.tf` / `example123.nix.tftpl`. The customer box gets the edge's
  WG public key from the `/signup` flow or `GET /pubkey`, not from a static
  tofu render. The edge box keeps its throwaway-key `wg0.conf` bootstrap (the
  binary owns the real key at runtime — that's not provisioning cruft).
- **One toml.** Provisioning secrets live in the same committed
  `nix/packages/cococoir/secretspec.toml` that `declare_secrets!` reads; the
  box deploys it as today. The typed loader only materializes `[profiles.default]`,
  so the extra `[profiles.provisioning]` + `[scopes.*]` blocks are inert to the
  edge binary. Single source of truth for the whole secret inventory.

## Acceptance criteria

- [ ] `provision-edge.sh` resolves the token via
      `secretspec export -P provisioning -S token` and token+admin via
      `-S provision`, instead of reading `HCLOUD_TOKEN`/a file directly.
      (Manual: `bash scripts/provision-edge.sh` reaches the `secretspec`
      export steps and `edge.env` carries `DNS_TOKEN`/`ADMIN_KEY_HASH`.)
- [ ] `edge.env`'s `ADMIN_KEY_HASH` equals `sha256(ADMIN_KEY)` where
      `ADMIN_KEY` is the generated persisted secret — stable across a
      second run (re-provision). (Manual: run provision twice; hash unchanged.)
- [ ] `gen-wg-keys.sh` is deleted; `provision-edge.sh` has no `wg` step and
      never touches `.secrets/wg/`. (L1: `tofu validate` + `main.tf` has no
      `edge_wg_pub`/`customer_wg_pub` locals, no `wg_public_keys` output.)
- [ ] `[profiles.default]` is byte-identical; `declare_secrets!` still
      resolves exactly the five runtime secrets. (L0: `secret::tests::*`
      green; the typed struct field set is unchanged.)
- [ ] `nix flake check` green (edge systemConfig evals; only the
      pre-existing `example123` placeholder fails). `cargo test` green.
- [ ] `docs/STATUS.md` updated in the same commit.

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

### T1: Add `[profiles.provisioning]` + `[scopes.*]` + provider to secretspec.toml
**Depends on:** none
**Verification:** `secretspec export -P provisioning -S token` and `-S provision`
resolve the right subsets from a scratch file store; `[profiles.default]`
unchanged.
**Files:** `nix/packages/cococoir/secretspec.toml`
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

### T3: Delete WG provisioning from tofu (main/render/outputs/template)
**Depends on:** none
**Verification:** `tofu validate` green; `main.tf` has no `edge_wg_pub` /
`customer_wg_pub` locals; no `wg_public_keys` output; `example123.nix.tftpl`
has no `edge_wg_pub` reference; `gen-wg-keys.sh` deleted.
**Files:** `remote-infra/tofu/main.tf`, `remote-infra/tofu/render.tf`,
`remote-infra/tofu/outputs.tf`, `remote-infra/tofu/templates/example123.nix.tftpl`,
`remote-infra/scripts/gen-wg-keys.sh` (delete)

### T4: Verify — L0, flake, tofu, STATUS.md
**Depends on:** T1, T2, T3
**Verification:** `cargo test` green (`secret::tests::*`); `nix flake check`
(edge systemConfig evals); `tofu validate`; double-run provision shows stable
`ADMIN_KEY_HASH`; `docs/STATUS.md` updated.
**Files:** `docs/STATUS.md`

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