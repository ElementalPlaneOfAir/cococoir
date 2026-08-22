# Admin API auth + secretspec — session resume file

Purpose: let an agent resume this arc on the 64GB build machine from an
SSH session without re-deriving context. Everything needed to continue.

## What this arc is

The control plane on `:8081` was unauthenticated. This arc: bearer admin
key auth + swagger UI (poem-openapi) + a secretspec secret layer. Status
doc lives at `docs/STATUS.md`; full design + alternatives +
acceptance criteria at `.specify/specs/admin-api-auth/proposal.md`.

## Design locked (read the proposal for rationale)

- **`secretspec_derive::declare_secrets!("secretspec.toml")`** — compile-time
  typed. Macro reads `secretspec.toml` (relative to `CARGO_MANIFEST_DIR`),
  generates typed `SecretSpec`: required secret → `String` (not Option);
  field names = lowercase of secret names (`DNS_TOKEN` → `dns_token`).
  A renamed/removed secret is a **compile error**.
- **Toml read at BOTH compile time AND runtime.** The macro's generated
  `load_internal` calls `secretspec::Secrets::load()`, which **walks up
  from the process CWD** for `secretspec.toml`. So the box needs the toml
  on disk, discoverable from `WorkingDirectory`. The edge unit sets
  `WorkingDirectory=/etc/cococoir`; dotenv provider URI is absolute
  `dotenv:/etc/cococoir/edge.env`.
- **One `std::sync::LazyLock<Resolved<SecretSpec>>` global** (`secret.rs`),
  sync, **panic-on-fail** (missing secret = catastrophic) — per the
  lifetimes principle, `LazyLock` not `OnceLock`/`tokio::OnceCell`.
  Forced early by `init_globals`.
- **LazyLock can't be seeded in tests** → DNS orchestrators +
  `customer_hostname` take `domain: &str`; `ControlPlane` holds
  `root_domain: &'static str` (injected; `new()` reads `secret::root_domain()`,
  `with_deps()` takes it as param). Round-trip test passes `"interdim.net"`.
- **Secret names dropped the `COCOCOIR_` prefix**: `DNS_ZONE_ID`,
  `DNS_ZONE_NAME`, `DNS_TOKEN`, `ROOT_DOMAIN`, `ADMIN_KEY_HASH` — these
  are the toml names, the Rust fields, AND the dotenv keys.
- **Admin key**: provision generates 128-bit (`openssl rand -hex 16`),
  echoes once, writes hash + convenience plaintext to `edge.env` (0600).
  **Hash is the declared secret; plaintext undeclared** (won't migrate).
- **Auth**: poem-openapi `SecurityScheme`, `ty="bearer"`, checker async
  `(&Request, Bearer) -> Option<Bearer>` (401 on None). Crypto = SHA-256
  of token + `subtle` constant-time compare vs `[u8; 32]`.

## Current state (verified)

- `cargo test` 145/145 green (incl. live Valkey round trip, auth
  `verify_token` unit tests, `secret` temp-toml resolution tests,
  endpoint 401 + spec + swagger tests).
- `cargo build --bins` both binaries.
- `tofu validate` green. `bash -n provision-edge.sh` OK.
- **`nix build .#systemConfigs.edge` FAILS** — see Blocker below. This
  is the real gate before deploy.

## BLOCKER: nix build fails on untracked files

The nix build of the crate (`src = ./.` in
`nix/packages/cococoir/default.nix`) only copies **git-tracked** files.
Three new files are untracked, so the sandbox build can't find them:
`pub mod secret;` → E0583, and `declare_secrets!` can't find the toml.

**Fix (before any deploy):**
```
git add nix/packages/cococoir/secretspec.toml \
        nix/packages/cococoir/src/controlplane/secret.rs \
        nix/packages/cococoir/src/controlplane/auth.rs
nix build .#systemConfigs.edge   # must pass now
```

Per AGENTS.md nothing is committed yet; review before committing.

## Files changed this arc (uncommitted)

- `nix/packages/cococoir/secretspec.toml` (NEW): 5 required secrets,
  value-free contract.
- `nix/packages/cococoir/src/controlplane/secret.rs` (NEW): `declare_secrets!`,
  `SECRETS` LazyLock (dotenv provider + `with_reason("cococoir-edge boot")`),
  `root_domain()`, `admin_key_hash()`, `decode_hash_hex`, temp-toml tests.
- `nix/packages/cococoir/src/controlplane/auth.rs` (NEW): `AdminKey`
  SecurityScheme, `verify_token(presented, &[u8;32])`, unit tests.
- `nix/packages/cococoir/src/controlplane/mod.rs` (MOD): `pub mod
  secret/auth`, re-exports, `ControlPlane` gains `root_domain` field
  (injected), `ControlPlaneApi` `#[OpenApi]` impl replaces 4 `#[handler]`s,
  `app()` nests `OpenApiService`+`swagger_ui()`+`spec_endpoint()`,
  ApiResponse status enums, endpoint tests appended, `init_globals`
  forces `secret::root_domain()` + `get_dns_api()`.
- `nix/packages/cococoir/src/controlplane/dns.rs` (MOD): deleted
  `HETZNER_DNS_CONFIG`/`DOMAIN`/`ensure_dns_config`; `DNS_CLIENT:
  LazyLock<HetznerDns>` via `from_secrets()`; orchestrators + `customer_hostname`
  take `domain: &str`.
- `nix/packages/cococoir/Cargo.toml` + `Cargo.lock` (MOD): added
  `secretspec = "0.19"`, `secretspec-derive = "0.19"`,
  `secrecy = { version = "0.10", features = ["serde"] }`,
  `sha2 = "0.11"`, `subtle = "2"`, `hex = "0.4"`.
- `nix/packages/cococoir/src/dashboard/components.rs` (MOD): pre-existing
  stray-` d` fix, not this arc.
- `remote-infra/tofu/templates/edge.nix.tftpl` (MOD): unit now has
  `WorkingDirectory="/etc/cococoir"` + `EnvironmentFile="/etc/cococoir/edge.env"`.
- `remote-infra/system-manager/edge.nix` (MOD): re-rendered copy of the
  template (same two fields).
- `remote-infra/scripts/provision-edge.sh` (MOD): idempotent nix install
  step; step 5 writes `edge.env` (new names + admin key/hash, 0600) +
  deploys `secretspec.toml`; generates+echoes admin key into
  `remote-infra/.secrets/admin.key`.
- `.specify/specs/admin-api-auth/proposal.md` (MOD): rewritten to the
  shipped design.
- `docs/STATUS.md`: NOT yet updated for this arc (needs a Works entry +
  proof).

## To apply on the server

```
git add nix/packages/cococoir/secretspec.toml \
        nix/packages/cococoir/src/controlplane/secret.rs \
        nix/packages/cococoir/src/controlplane/auth.rs
nix build .#systemConfigs.edge          # gate; must pass
bash remote-infra/scripts/provision-edge.sh   # tofu apply + sm switch + secrets
```

provision-edge.sh now: idempotent nix install (skips if present), writes
`edge.env` + `secretspec.toml` to `/etc/cococoir/`, generates+echoes the
admin API key once (also saved to `remote-infra/.secrets/admin.key`).

Then verify with the echoed key:
```
curl -H "Authorization: Bearer <key>" http://<edge-ip>:8081/customers
curl http://<edge-ip>:8081/openapi.json    # has AdminKey scheme
curl http://<edge-ip>:8081/docs            # swagger UI
curl http://<edge-ip>:8081/pubkey          # open
```
No/wrong key → 401.

## Gotchas

- secretspec `require_reason` default = `"agents"` (only agents need a
  reason). Production builder still sets `with_reason` for the audit log.
- The macro's generated `load()` needs direct `secrecy` + `serde` deps
  on 0.19.
- `secretspec-derive` is a separate crate, published at 0.19.1; 0.20 is
  unreleased (main = 0.19.1) — no git pin.
- `/tmp/opencode/ssderive.rs` has the fetched derive source (macro codegen
  details: field assignment, load_internal, require_reason).
- Don't wipe `remote-infra/.secrets/admin.key` — re-provision mints a new
  key and the old one dies.

## Verification commands

```
cargo test                      # 145/145
cargo build --bins
nix flake check                 # edge systemConfig evals; only pre-existing
                                #   example123 btrfs placeholder fails
tofu -chdir=remote-infra/tofu validate
nix build .#systemConfigs.edge  # must be green BEFORE deploy
```