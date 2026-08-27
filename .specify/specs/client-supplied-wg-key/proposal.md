# Client-supplied WireGuard key + idempotent signup

Status: implemented (cargo test 142 green, `nix flake check` 23/23 incl. `edge-forward` L2).

## Premise

Remote access for amon-sul needs the customer box to wire its own wg0. The
agreed architecture (STATUS "Next move" #2) moves WG keygen into the client
dashboard: **the client generates + persists its own keypair, sends only the
public key to the edge, and the edge never holds a customer private key.**
Today `POST /signup` does the opposite — the server generates the keypair
(`generate_wg_keypair`, `mod.rs:414`) and returns the private key once.

The customer dashboard needs to be able to (re)call `/signup` safely: a
re-boot or re-provision must not burn a new `/128` or hard-fail on an
existing username. So `/signup` must accept a client `public_key`, be
**idempotent**, and **rotate the WG peer key** when the username already
exists with a different key.

If we don't build it: the customer side of the signup flow stays the
`peers = []` gap (the migration proposal's T8), and the box cannot be
reached remotely — the whole amon-sul migration stalls at the remote-access
gate.

## Acceptance criteria

- [x] **L0** `cargo test -p cococoir-controlplane` green, including new
      tests: idempotent same-key re-signup returns the same `/128`+`wg_ip`
      and does **not** increment the alloc counter; different-key re-signup
      removes the old WG peer, adds the new one with the same `/128`+`wg_ip`,
      and updates the stored customer; invalid public key → clear error;
      response no longer contains `wg_private_key`. Maps to T1, T2.
- [x] **L1** `nix flake check` green — the updated `edge-forward` nixosTest
      renders (the customer generates its own keypair and passes the public
      key to signup). Maps to T3.
- [x] **L2** the `edge-forward` nixosTest data path still passes
      (signup → `/128` forward → WG → customer box → HTTP), with the
      customer wg0 configured from its **own** generated private key, not
      one returned by the server. Maps to T3.
- [x] OpenAPI spec: `/signup` request carries `public_key`; the response
      has no `wg_private_key` field; the spec-gating test updated. Maps to
      T2.

## Smallest version

`POST /signup` accepts `{ username, public_key }`, is idempotent, and
rotates the peer key on an existing route. The response drops
`wg_private_key`. The L2 `edge-forward` test and the customer-side render
are updated to generate the keypair client-side. No NixOS module changes;
the admin-key auth stays (the future website-signup device token is
separate work).

## Alternatives considered

- **Keep server-side keygen, add rotation only** — case for: minimal diff.
  Case against: preserves the "edge holds/returns customer private keys"
  smell we are explicitly killing, and forces the dashboard to trust a key
  it doesn't own. Rejected.
- **Separate `/rotate` endpoint, leave `/signup` creating-only** — case
  for: narrow, explicit primitive. Case against: a client boot would need
  two round-trips and still can't safely replay signup; folding rotation
  into an idempotent signup is one call the dashboard can retry. Rejected.
- **Return a private key AND accept a client key (backward compat)** —
  case for: no breaking change. Case against: two code paths for the same
  contract, and the private-key path is the one we're removing. Rejected.
- **Idempotent on the username only (ignore key change)** — case for:
  simplest. Case against: a re-provisioned box with a fresh key could never
  reach the tunnel again; rotation is the point. Rejected.

Why the winner wins: one endpoint, one call the dashboard can replay, no
private key ever crosses the wire, and the existing admin-key auth already
guards the operation.

## Architecture decisions

No new ADR — this extends ADR-025's decision that "the client generates +
persists its own keypair, sends only the pubkey to the edge; edge never
holds customer private keys" (already recorded in STATUS/PLAN as the agreed
architecture). It also fixes a latent idempotency bug: the current signup
runs `INCR` *before* the duplicate check, so a repeat signup wasted a
`/128` even though it errored. The new flow checks existence first.

- **Key validation**: the supplied `public_key` must decode as 32 bytes of
  base64 (a well-formed WG public key). Cheap check; the kernel re-validates
  on `wg set`. New `ControlPlaneError::InvalidPubkey`.
- **Rotation ordering**: `remove_peer(old)` then `add_peer(new)` with the
  *same* `wg_ip`. Order matters — two peers sharing the `/32` allowed-ips
  would make routing ambiguous, so the old key must go first. A brief tunnel
  drop during re-key is inherent.
- **Same-key repeat** = idempotent no-op (re-ensure the peer, return the
  existing route). **Different-key repeat** = rotation, `/128`+`wg_ip`
  unchanged, stored `wg_public_key` updated.

## Tasks

### T1: make `/signup` accept a client public key + drop the private key
**Depends on:** none — DONE
**Verification:** `cargo test -p cococoir-controlplane` green; `SignupResponse`
has no `wg_private_key`; signup rejects an invalid pubkey. L0.
**Files:** `crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/wg.rs`

`SignupRequest` gains `public_key`; `signup(username, public_key)` validates
it, builds the customer from the client key (no `generate_wg_keypair`), and
`SignupResponse` drops `wg_private_key`. Add `ControlPlaneError::InvalidPubkey`
and a `validate_wg_pubkey` helper. The API handler maps `InvalidPubkey` →
400, keeps `Created`/`Conflict`/`Internal`, adds an `Ok`(200) variant.

### T2: idempotent + rotate
**Depends on:** T1 — DONE
**Verification:** new L0 tests: same-key re-signup returns the same
`/128`+`wg_ip` with no alloc-counter increment; different-key re-signup
removes the old peer, adds the new one with the same route, and persists the
new `wg_public_key`. L0 + updated spec-gating test. L1.
**Files:** `crates/controlplane/src/controlplane/mod.rs`

Check existence first; on hit, same key → re-ensure peer + return; different
key → `remove_peer(old)` + `add_peer(wg_ip,new)` + persist. Allocate only on
the not-found path (fixes the wasted-INCR bug). Update the OpenAPI spec test.

### T3: update the L2 `edge-forward` test for client-side keygen
**Depends on:** T1, T2 — DONE
**Verification:** `nix flake check` green and the `edge-forward` nixosTest
data path passes. L1 + L2.
**Files:** `nix/tests/edge/default.nix`

The test generates the customer keypair on the client box (`wg genkey` +
`wg pubkey`), passes the public key in the signup body, and configures wg0
from the client's own private key (dropping the `wg_private_key` read).

## Strongest objection

Making `/signup` an idempotent **update** primitive under the same
admin-key auth means anyone holding the admin token can silently rotate any
customer's WG key and take over their tunnel — the rotation path converts a
create-only endpoint into a hijack primitive. It is bounded (still admin-key
gated, the future website-signup device token is the intended hardening) but
it widens what a leaked key can do, and the "rotate then re-verify"
requirement is deferred (the dashboard is trusted). Defense: the alternative
is a box that can never re-provision its tunnel, and the auth is unchanged
from the current signup; the idempotency + existence-first restructure also
removes a real `/128`-leak bug. The remaining risk is that a long-lived
admin key becomes more valuable; that is the existing surface, not a new one.