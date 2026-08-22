# Admin API auth + swagger UI + secretspec secret layer

## Premise

The control plane on `:8081` (signup, delete, list, pubkey) is
completely unauthenticated. Before the edge goes live for a collaborator
demo, anyone who can reach the port can create/delete customers and burn
`/128` allocations. This arc adds a bearer admin key, requires it on
every control-plane endpoint except `/pubkey` (the WG public key is
meant to be public — a convenient debug check and no secret), and
converts the plain-`poem::Route` app to `poem-openapi` so the control
plane gets a swagger UI with an Authorize button for debugging.

Health endpoints stay open by construction: they live in a separate
process on `127.0.0.1:9090` (`health.rs`), already outside the API port.

A real secret store (OpenBao/BWS/SOPS) is likely in this project's
future — secrets have been a recurring pain point in past projects — so
this arc also lays the **secretspec seam** under the existing DNS +
admin config: a declarative `secretspec.toml` (the contract, no values),
a dotenv provider today, and a provider-URI swap later with zero code
change.

## Decisions locked with the operator

- **secretspec 0.19.1** (crates.io max; docs describe unreleased 0.20;
  `main` is still 0.19.1, no v0.20 tag exists — nothing to git-pin).
  `nixpkgs`'s CLI is 0.10.1 — ten versions stale — so **no CLI anywhere**
  in the deploy path. Provision writes the dotenv file directly; the
  process resolves via the **embedded Rust SDK**.
- **Compile-time typed secrets via `secretspec_derive::declare_secrets!`
  (`secretspec-derive` 0.19.1)** — not the untyped runtime
  `Secrets::load_from` API. The macro reads `secretspec.toml` at compile
  time (relative to `CARGO_MANIFEST_DIR`) and generates a typed
  `SecretSpec` struct: a required secret is a `String` (not an
  `Option`), and field names are the lowercase of the secret names
  (`DNS_TOKEN` → `dns_token`). A renamed/removed secret is a **compile
  error**, never a silent runtime surprise. Earlier this arc wrongly
  framed "compile-time" as rejected; it was not — it is the better
  guarantee and was adopted.
- **The toml is read at BOTH compile time and runtime.** The macro's
  generated `load_internal` calls `secretspec::Secrets::load()`, which
  **walks up from the process CWD** looking for `secretspec.toml`
  (`find_config_file` → `find_config_file_from(current_dir)`). So the
  box needs the toml on disk, discoverable from the process working
  directory. Fix: the edge systemd unit sets
  `WorkingDirectory=/etc/cococoir` (both `secretspec.toml` and
  `edge.env` live there). The dotenv provider URI is the absolute path
  `dotenv:/etc/cococoir/edge.env`.
- **All five edge values flow through secretspec** (zone_id, zone_name,
  token, root_domain, admin_key_hash) — one secret layer, no
  `std::env::var` dual mechanism. The process resolves once at boot.
  Secret names dropped the `COCOCOIR_` prefix (`DNS_TOKEN`, not
  `COCOCOIR_DNS_TOKEN`) — these names are the toml names, the Rust
  fields, AND the dotenv keys in `edge.env`.
- **One `std::sync::LazyLock<Resolved<SecretSpec>>` global** (`secret.rs`),
  sync, resolving file IO, **panic-on-failure** (a missing secret is
  catastrophic — the box cannot run without its DNS zone + admin key) —
  per `writing/human/lifetimes_in_rust.md`, `LazyLock` (not
  `OnceLock`/`tokio::OnceCell`) is the honest tool for "sync,
  guaranteed-never-fail-or-halt". It is forced early by `init_globals`.
- **Because a `LazyLock` cannot be seeded from tests**, the DNS
  orchestrators take `domain: &str` explicitly, and `ControlPlane` holds
  `root_domain: &'static str` (injected at construction; `new()` reads
  `secret::root_domain()`, `with_deps()` takes it as a param). This is
  what lets the round-trip test pass `"interdim.net"` without touching
  the boot-only secrets global. No test ever reads the unseedable
  `SECRETS`.
- **Admin key stays operator-side**: provision generates a 128-bit key
  (`openssl rand -hex 16`) if absent, echoes it once, writes hash +
  convenience plaintext to `edge.env` (0600). **The hash is the declared
  secret**; the plaintext line is undeclared — so when the dotenv
  provider is swapped for OpenBao later, the plaintext deliberately does
  not migrate. secretspec is the transport, not the crypto.
- **Rejected: `command`-type hash derivation** (generate a hash from
  another secret's output). Not a documented secretspec capability —
  composed secrets are raw string concatenation, not computation.
- **`sha2` + `subtle`** for the constant-time check; the hash hex
  decode is a small pure `decode_hash_hex` fn (unit-testable) — no
  hand-rolled encoder. All deps already in the lockfile.

## Acceptance criteria

- [x] `POST /signup`, `GET /customers`, `DELETE /customers/:username`
      require `Authorization: Bearer <admin-key>`; without it → 401.
      (L0: `signup_requires_auth`/`list_customers_requires_auth`/
      `delete_customer_requires_auth` — auth fails at request
      extraction, before any global is read)
- [x] `GET /pubkey` stays open (no auth). (L0: `spec_gates_protected_ops`
      asserts /pubkey declares NO security requirement in the derived
      spec; the handler path needs the live store, covered by
      `redis_store_round_trip`)
- [x] The key check is SHA-256 of the presented token compared in
      constant time against the hash from `ResolvedSecrets`. (L0:
      `verify_token` unit tests — right key passes, wrong/missing/
      different-hash fail; `decode_hash_hex` rejects malformed hash)
- [x] All five edge secrets resolve through secretspec 0.19.1 into one
      `SECRETS` static; DNS + auth read from it, not env. (L0:
      `secret::tests::*` resolve a temp toml mirroring the real contract
      + a temp dotenv via the untyped `load_from`+`resolve` machinery;
      missing required secret fails, value-free on failure)
- [ ] The env file is renamed `dns.env` → `edge.env` (DNS + admin
      auth); `provision-edge.sh` generates the 128-bit admin key (if
      absent), echoes it once, writes hash + plaintext to `edge.env`
      (0600); the unit sets `WorkingDirectory=/etc/cococoir` and
      `secretspec.toml` is deployed alongside. (T6)
- [x] The control plane serves a bundled swagger UI at `/docs` (and
      `/openapi.json`), mirroring `health.rs`; the spec declares the
      bearer security scheme so the Authorize button works. (L0:
      `swagger_ui_served_at_docs`; `spec_gates_protected_ops`)

## Smallest version

- `controlplane/secret.rs`: `declare_secrets!("secretspec.toml")`,
  `SECRETS: std::sync::LazyLock<secretspec::Resolved<SecretSpec>>`
  (dotenv provider, panic-on-fail), `root_domain()`,
  `admin_key_hash()`, `decode_hash_hex`. Deps: `secretspec = "0.19"`,
  `secretspec-derive = "0.19"`, `secrecy = { version = "0.10",
  features = ["serde"] }` (generated code needs these on 0.19),
  `sha2 = "0.11"`, `subtle = "2"`, `hex = "0.4"`.
- `controlplane/dns.rs`: delete `HETZNER_DNS_CONFIG`/`DOMAIN`/
  `ensure_dns_config` LazyLock stack; `HetznerDns::from_secrets()`
  reads `SECRETS.secrets.{dns_zone_id,dns_zone_name,dns_token}`;
  `DNS_CLIENT: LazyLock<HetznerDns>`; `get_dns_api()` → `&*DNS_CLIENT`;
  orchestrators + `customer_hostname` take `domain: &str`.
- `controlplane/auth.rs`: `AdminKey` security scheme (poem-openapi
  `#[derive(SecurityScheme)]`, `ty = "bearer"`, checker =
  `check_admin_key`, async `(&Request, Bearer) -> Option<Bearer>`);
  `verify_token(presented, &[u8; 32])` pure constant-time check.
- `controlplane/mod.rs`: convert plain handlers (`signup`,
  `list_customers`, `delete_customer`, `edge_pubkey`) to a
  `ControlPlaneApi` `#[OpenApi]` impl (`OpenApiService` + `swagger_ui()`
  + `spec_endpoint()`, mirroring `health.rs`). The auth-extracted
  `AdminKey` param gates every op except `/pubkey`. HTTP status mapping
  (`201`/`400`/`409`, `200`/`500`, `204`/`404`/`500`) becomes explicit
  `ApiResponse` enums. `ControlPlane` gains `root_domain: &'static str`
  (injected); `init_globals` forces `secret::root_domain()` +
  `get_dns_api()` first.
- `app()` returns the `OpenApiService`-nesting `Route`. `edge.rs`
  unchanged (still calls `app()`).
- `nix/packages/cococoir/secretspec.toml` (new, committed): the five
  required secrets under `[profiles.default]`, value-free. (Must live
  next to the crate — `CARGO_MANIFEST_DIR` for compile time; and be
  deployed to `/etc/cococoir/` for runtime CWD discovery.)
- `provision-edge.sh`: generate 128-bit key into gitignored
  `.secrets/admin.key` if absent; write `ADMIN_KEY_HASH` (sha256sum) +
  `ADMIN_KEY` (the convenience plaintext) + the DNS values into
  `/etc/cococoir/edge.env` (0600); echo the key once to the operator.
- Rename `dns.env` → `edge.env` in the tofu template + rendered
  `edge.nix`; deploy `secretspec.toml`; set
  `WorkingDirectory=/etc/cococoir`.

Deferred: rotating keys, multi-admin keys, per-customer scoping, rate
limiting, the OpenBao/BWS/SOPS provider swap (the seam is the point;
the swap is a URI change when a store exists).

## Alternatives considered

- **Untyped `Secrets::load_from(path)` runtime API instead of
  `declare_secrets!`** — case for: no compile-time toml coupling in the
  Nix build. Case against: manual `resolve_named("NAME")` string lookups
  couple to the same names but lose the compile-time rename/removal
  guarantee — exactly what bit us with env-var drift. The macro reads
  the toml at compile time relative to `CARGO_MANIFEST_DIR` (no runtime
  coupling beyond the CWD-walk for values), so it is the strictly
  stronger seam. Rejected in favor of `declare_secrets!`.
- **`tokio::sync::OnceCell` for `SECRETS`** — case for: matches the
  control-plane process globals, and is seedable in tests. Case against:
  resolution is sync file IO that must never fail (or is catastrophic),
  so `LazyLock` is the honest lifetime tool; the seedability is bought
  back by injecting `root_domain` into `ControlPlane` instead. Rejected.
- **`ApiKey` header instead of bearer** (`X-Admin-Key`) — case for: no
  `Bearer` prefix to strip. Case against: bearer is the standard,
  poem-openapi's `SecurityScheme` supports both, and the Authorize
  button in swagger is built for bearer. Rejected.
- **HMAC-signed requests** — case for: protects the key from replay.
  Case against: overkill for a demo control plane on a box the operator
  already SSHes into; the admin key is not a per-request credential.
  Rejected.
- **bcrypt the key** — case for: matches the dashboard. Case against:
  a random 128-bit key has enough entropy that stretching is wasted
  compute; SHA-256 + constant-time compare is the correct tool (the
  dashboard's bcrypt is for human passwords, a different problem).
  Rejected.
- **Leave handlers as `poem::Route`, auth via a middleware** — case
  for: no `#[OpenApi]` conversion. Case against: you cannot derive an
  OpenAPI spec from plain `Route` handlers, so swagger is impossible;
  the conversion buys both auth (declared security scheme → Authorize
  button) and the spec in one change. Rejected.
- **Guard `/pubkey` too** — case for: "everything behind auth". Case
  against: it exposes only a public WG key; keeping it open is a
  useful operator debug check and the signup response already carries
  the key. Rejected (matches user decision).
- **Per-secret `LazyLock<Result<...>>` statics reading env** — case
  for: matches the current DNS shape, smallest diff. Case against: two
  fail-fast points, three statics to keep in sync, and no seam for the
  future secret store. Rejected in favor of one `SECRETS` `LazyLock` —
  one boot point, one source of truth.
- **Adopt secretspec via the nixpkgs CLI** — case for: no Rust dep.
  Case against: nixpkgs pins 0.10.1 vs crates.io 0.19.1; a ten-version
  gap is a trust defect in the deploy path. Rejected — the embedded SDK
  pins the version in the flake's lockfile where it is verifiable.
- **`command`-type hash generation** — case for: hash "for free" from
  the key. Case against: not a documented secretspec capability
  (composed secrets are string concatenation, no computation). Rejected.

## Architecture decisions

Extends ADR-025's control-plane slice. The `SecurityScheme` + checker
pattern is poem-openapi 5.1.16's documented bearer auth (the derive
calls `#path(&req, #from_request?).await`, then
`CheckerReturn::from(...).into_result()?`); the swagger UI mirrors the
`health.rs` precedent (bundled, no CDN). The `SECRETS` `LazyLock` is a
sync, never-fail-else-halt process global (per the lifetimes doc), the
same shape as the DNS `LazyLock`s it feeds, all derived from one
source. `declare_secrets!` gives compile-time typing: field names are
the lowercase secret names, a renamed secret is a compile error. The
toml is read at runtime too (CWD-walk), so the unit sets
`WorkingDirectory=/etc/cococoir`. The plaintext-in-file is a documented
convenience: the process reads only the hash, and the plaintext is
*undeclared* so it cannot migrate to a future store. Hash crypto is
SHA-256 + constant-time compare (`sha2` + `subtle`), correct for a
random 128-bit key.

## Tasks

### T0: Fix corrupted working-tree edit in `dashboard/components.rs`
**Depends on:** none
**Verification:** `cargo check` compiles the dashboard
**Files:** `src/dashboard/components.rs`
**Note:** A stray ` d` in the working tree broke the build (uncommitted
editor artifact, not part of this proposal's diff).

### T1: `secret.rs` — `declare_secrets!` + `SECRETS` LazyLock + deps
**Depends on:** none
**Verification:** `secret_*` unit tests — resolution from a temp
`secretspec.toml` mirroring the real contract + a temp dotenv lands all
five values (via the untyped `load_from`+`set_provider`+`resolve`
machinery, since `SECRETS` is not test-seedable); missing required
secret fails + value-free; `decode_hash_hex` rejects malformed hash
**Files:** `src/controlplane/secret.rs` (new),
`src/controlplane/mod.rs` (mod + re-export), `Cargo.toml` (add
`secretspec = "0.19"`, `secretspec-derive = "0.19"`,
`secrecy = { version = "0.10", features = ["serde"] }`,
`sha2 = "0.11"`, `subtle = "2"`, `hex = "0.4"`)

### T2: `dns.rs` — read from `SECRETS`, delete LazyLock stack
**Depends on:** T1
**Verification:** `dns_*` tests green after removing
`HETZNER_DNS_CONFIG`/`DOMAIN`/`ensure_dns_config`; `get_dns_api()`
returns `&*DNS_CLIENT`; orchestrators + `customer_hostname` take
`domain: &str`; `from_env_missing_config_is_err` replaced by a
`secret.rs`-level resolution test
**Files:** `src/controlplane/dns.rs`

### T2b: `mod.rs` — `root_domain` injection into `ControlPlane`
**Depends on:** T2
**Verification:** `cargo check`; `redis_store_round_trip` passes
`"interdim.net"` via `with_deps` and never touches `SECRETS`;
`init_globals` forces `secret::root_domain()` + `get_dns_api()`
**Files:** `src/controlplane/mod.rs`

### T3: `auth.rs` — `AdminKey` security scheme + constant-time check
**Depends on:** T1
**Verification:** `auth_*` unit tests — `verify_token` passes the right
key, rejects wrong/missing/different-hash (pure fn, no `SECRETS`)
**Files:** `src/controlplane/auth.rs` (new),
`src/controlplane/mod.rs` (mod + re-export)

### T4: Convert handlers to `ControlPlaneApi` `#[OpenApi]` + auth gate
**Depends on:** T2, T3
**Verification:** endpoint tests via poem-openapi `TestClient` — no
header → 401 on signup/list/delete (auth fails at extraction, no globals
needed); `/pubkey` open (spec-level); success paths covered by
`redis_store_round_trip` at the store layer
**Files:** `src/controlplane/mod.rs`

### T5: Swagger UI + `/openapi.json` on the control plane
**Depends on:** T4
**Verification:** `app()` nests `service` + `swagger_ui()` +
`spec_endpoint()` (mirroring `health.rs`); spec JSON declares the
bearer security scheme; endpoint test fetches `/docs` and
`/openapi.json` and asserts protected ops require it while /pubkey does
not (the tripwire against silently opening a handler)
**Files:** `src/controlplane/mod.rs`

### T6: `secretspec.toml` + `provision-edge.sh` admin key + `edge.env` rename
**Depends on:** T1
**Verification:** script writes `edge.env` with hash + convenience
plaintext, mode 0600, key echoed once; `secretspec.toml` deployed to
`/etc/cococoir/`; unit sets `WorkingDirectory=/etc/cococoir` +
`EnvironmentFile=/etc/cococoir/edge.env`; `tofu validate`; re-render
`edge.nix`; edge systemConfig evals
**Files:** `nix/packages/cococoir/secretspec.toml` (new),
`remote-infra/scripts/provision-edge.sh`,
`remote-infra/tofu/templates/edge.nix.tftpl`,
`remote-infra/tofu/outputs.tf` (if needed),
`remote-infra/system-manager/edge.nix` (re-rendered)

### T7: Full verify — L0 + live Valkey round trip + binaries + flake
**Depends on:** T6
**Verification:** `cargo test` all green (incl. live round trip against
Valkey, now with admin key exercised); `cargo build --bins`; `nix flake
check` (edge systemConfig evals; only pre-existing `example123`
placeholder fails); `tofu validate` green
**Files:** (verification only)

## Strongest objection

A bearer key checked against a hash stored in the same dotenv file as
its plaintext is, at the moment it is introduced, **not a security
boundary at all** — anyone with read access to `edge.env` (root, or any
process running as root, of which there are several on this box) has
the key. The design's only honest claim is that it is the *skeleton* of
a boundary: the process consumes only the hash, the plaintext is
undeclared (so it cannot migrate), and moving the declared hash to a
stricter store (OpenBao/BWS/SOPS) is a provider-URI change in
`secretspec.toml`, not a code change. Shipping an auth scheme that
doesn't actually protect against the box's real threat model — and that
could lull the operator into thinking the API is safe when the file is
world-adjacent — is the danger. A second objection is that adopting
secretspec 0.19.1 (a pre-1.0 crate) pins the project to a moving API
the docs describe as 0.20 (unreleased); the mitigation is the `SECRETS`
seam, which isolates the crate behind one module and makes a future
bump or a hand-rolled replacement a single-module change. The
mitigation for both is being explicit that this is convenience gating,
not a security boundary, until the plaintext is gone and a real store
holds the hash; the risk is that this clarity is lost and the 0600-mode
file is assumed to be protection it is not.