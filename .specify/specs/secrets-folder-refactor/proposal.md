# secrets/ — one editable folder at repo root

## Premise

The provisioning surface is scattered: secrets live in
`remote-infra/.secrets/` (sops), facts live in `terraform.tfvars` (gitignored),
`secretspec.toml` (root), `variables.tf` defaults (tofu), and the
`remote-infra/README.md` walkthrough. On a fresh clone there is no single
place that says "edit me". The user moved ssh keys by hand into tfvars
and immediately hit the confusion this creates.

Interview answers: secret values come from one sops store; non-secret
configurable values live in the same folder, committed raw and
plaintext; machine secrets keep arriving by provision-time push
(edge.env), never by sops-decrypt-at-eval. Per-machine sops stores are
deferred until a second machine justifies a second age identity.

## Acceptance criteria

- [ ] `secrets/` at repo root is the only folder a fresh-clone operator
  touches: one committed facts file (plaintext, JSON) + one gitignored
  sops file. Verified by the README walkthrough pointing only at that folder.
- [ ] No plaintext secret values are committed: gate check asserting
  `git ls-files` contains no `terraform.tfvars` and no non-encrypted
  (`*.enc.*` excluded) secret file under `secrets/`. Amendment during
  T4: the encrypted store stays committed (age-encrypted at rest), and
  the tripwire runs inside `scripts/status.sh` (git is available
  there; a pure-eval derivation cannot see `git ls-files` — same
  mechanism as the existing `provisioning-store` tripwire).
- [ ] Flake evaluates with zero decrypted secrets: the facts file is
  committed JSON; `nix eval` of any machine config needs no age key.
- [ ] tfvars no longer holds any config the operator should edit:
  tofu inputs arrive from `-var-file` generated from facts + sops at
  apply time by `provision-edge.sh`; the static `terraform.tfvars*`
  files are deleted.
- [ ] `nix run .#secretspec -- export ...` resolves from the moved store;
  `provision-edge.sh` end-to-end still functions (smoke run to Hetzner,
  or a stubbed dry-run flagged in STATUS.md if operator credentials absent).
- [ ] `secrets/secrets.enc.yaml` decrypts with `sops --decrypt` locally
  and MAC validates after the move.

## Smallest version

Everything above ships together; the store move and the facts file are
one coherent decision. Explicitly deferred: render.tf tftpl deletion and
converting `remote-infra/nix/example123.nix` + `system-manager/edge.nix`
into real committed files importing the facts JSON (the follow-up
proposal), per-machine sops stores, sops-nix style age-key rotation UX.

## Alternatives considered

- **Encrypt the whole tfvars file in sops** — one-file story is nice;
  against: encrypts public facts, destroys reviewability in PRs, and
  hands a compromised provisioning identity the infra topology too.
  Rejected.
- **One master sops file for everything, field-level keys** — sops
  cannot do per-field recipients (single data key per file). The
  provisioning-secret/machine-secret split already exists as file
  separation; regressing it would let an edge-read key decrypt
  HETZNER_TOKEN. Rejected on security.
- **Machine secrets decrypted at nix-eval/build time (sops at eval)** —
  makes `nix flake check`, CI, and vmtest unusable without the operator
  age key; this is the documented sops-nix failure mode. Provision-time
  push (status quo via the secretspec SDK + edge.env) keeps eval pure.
  Rejected.
- **Keep store under remote-infra/.secrets, skip the move** — zero diff
  risk; against: the fresh-clone ergonomics complaint never goes away
  and facts remain gitignored. Rejected; gitignore tripwire below buys
  back the diff risk.
- **Winner:** root `secrets/` folder — committed `facts.json` (domains,
  subnets, hosts, ssh public keys, ports) + gitignored
  `secrets.enc.yaml`. Both plain and encrypted config are value-edits in
  one folder; eval stays pure; only genuinely secret values are encrypted.

## Architecture decisions

- No new ADR: this realizes the existing "secrets → sops store, secretspec
  contract, provision-time push" decision (see remote-infra/README.md and
  secretspec.toml header comments). The facts.json change is the seeds of
  the follow-up "facts → infra-vars consumed by the flake" ADR; write
  that ADR when the render.tf follow-up lands.

## Tasks

### T1: create `secrets/`, move the store
**Depends on:** none
**Verification:** `sops --decrypt secrets/secrets.enc.yaml > /dev/null`; `git check-ignore -v secrets/secrets.enc.yaml` matches the new rule
**Files:** `secrets/` (new, inc. moved `.enc.yaml`), `secretspec.toml`, `.gitignore` + `remote-infra/.gitignore`

- [x] DONE — store moved (`git mv`), secretspec provider path and both
  .gitignore rules updated, secretspec SDK export + raw `sops --decrypt`
  both resolve from the new path, plaintext decryptions ignored.
  Amendment recorded above: the encrypted store stays committed.
  Also added `.terraform.lock.hcl` to remote-infra/.gitignore (was only
  in the root ignore).

### T2: committed facts.json as the single plain-config source
**Depends on:** T1
**Verification:** tree contents match current tfvars + variables.tf defaults (diff against old tfvars); `nix eval --file secrets/facts.json` equivalent (`builtins.fromJSON (builtins.readFile ...)`) evaluates
**Files:** `secrets/facts.json` (new), `remote-infra/tofu/variables.tf` (defaults now reference nothing secret), provision script

- [x] DONE — `secrets/facts.json` committed (all tofu variables,
  explicit, incl. the operator's hand-edited ssh key); `variables.tf`
  stripped of defaults (schema only — facts.json is the authority, a
  stale default can no longer diverge silently); verified
  `builtins.fromJSON (builtins.readFile ./secrets/facts.json)` in Nix
  eval AND `tofu validate -var-file=../../secrets/facts.json` green,
  `tofu fmt` applied.

### T3: provision script derives tofu inputs
**Depends on:** T2
**Verification:** `provision-edge.sh` builds a `-var-file` by merging facts.json with sops-decrypted values; delete `terraform.tfvars` + `.tfvars.example`; README walkthrough rewrite (one folder)
**Files:** `remote-infra/scripts/provision-edge.sh`, `remote-infra/README.md`, tofu tfvars deletions

- [x] DONE — script asserts facts.json exists and applies with
  `-var-file="$FACTS"` (a plain `tofu apply` now fails loudly on
  missing vars instead of silently using stale defaults). tfvars +
  example deleted (rm + `git rm --cached` — they were tracked).
  README layout/setup/modify sections rewritten around `secrets/`.
  Live tofu apply deferred: the edge box is deployed and real; next
  operator re-provision exercises the new path in production.

### T4: gitignore tripwire (constitution §7)
**Depends on:** T1
**Verification:** L1 eval assertion — CI/devshell check asserting `git ls-files` never names `secrets/*.enc.yaml` or `terraform.tfvars`; run green
**Files:** `nix/tests/` or an existing L1 check file, `.gitignore`

- [x] DONE — `secrets-hygiene` tripwire in `scripts/status.sh`
  (amendment above: runs where git is available). Verified both ways:
  planted plaintext `secrets/testing-leak.env` → status.sh exits 1
  naming the leak; cleaned tree → exit 0, `secrets-hygiene — PASS`.
  Plus `secrets/*.dec.*` / `secrets/plaintext/` gitignore rules for
  accidental decrypted outputs.

## Strongest objection

A repo-root `secrets/` folder widens the blast radius of a gitignore
mistake: everything under `remote-infra/.secrets/` was isolated by one
path and readers' learned habit; now a typo'd pattern or a
`git add secrets/` out of habit can commit the (encrypted, yes — but
metadata-bearing) store next to committed plaintext facts, making a
future plaintext leak one bad rename away. The gitignore tripwire (T4)
mitigates but cannot eliminate the human factor, and "clone and edit one
folder" would also have been answered by a README quickstart pointing at
two paths in the existing layout — the actual honest cost is two files.
