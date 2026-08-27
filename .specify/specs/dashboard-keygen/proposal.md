# Dashboard-keygen — client owns wg0 + its WireGuard key

Status: implemented T1–T5 (cargo test green, `nix flake check` 12/12 incl.
the client-owned `edge-forward` L2). T6 (deploy) pending root on amon-sul.

## Premise

The wg0 `fopen: No such file or directory` failure on amon-sul is a
design bug, not an ops slip: wg0's private key is a static file an
operator must hand-write, and it must coincidentally match the pubkey
registered on the edge. That is a silent-failure seam — exactly the class
AGENTS.md bans. We keep patching it (`write the key file`, `restart
wg0`) because the client does not own the tunnel.

The structural fix, and the agreed Next move #3: **the client owns wg0
and its keypair.** `cococoir-client` generates + persists its own WG
keypair, brings up wg0 itself, and (once a customer-auth token exists)
registers via the now-idempotent `/signup`. This removes the operator
key-file step, the `fopen` fragility, and the edge-holds-keys smell. My
`/signup` change (client-supplied key, idempotent, rotation) was the edge
half; this is the client half.

Decision (user): **full drop** — the client owns the entire wg0
interface, not just the key. The NixOS `networking.wireguard.interfaces.wg0`
module is removed.

If we don't build it: every box re-provision hits the manual key-file
step, which breaks silently, and amon-sul's remote access stays down.

## Acceptance criteria

- [x] **L0** `cargo test -p cococoir-client` green: `ensure_keypair` is
      idempotent (generates once, persists 0600, never regenerates an
      existing key); `bring_up_wg0` issues the expected `ip`/`wg` command
      sequence (interface ensure, key, peer, addr, up) and is idempotent
      against an existing interface/addr. Maps to T1.
- [x] **L1** `nix flake check` green; the client unit renders with
      `path = [iproute2 wireguard-tools]` and no `after =
      wireguard-wg0.service`; amon-sul renders with no
      `networking.wireguard` and a `tunnel` config. Maps to T3, T4.
- [x] **L2** the `edge-forward` nixosTest still passes with the customer
      box's wg0 created by the client process (not the NixOS module) from
      its persisted keypair. Maps to T5.
- [x] A `nix eval` of amon-sul shows the tunnel config carries the edge
      pubkey/endpoint and `10.10.0.3/24`; no `wireguard-wg0` unit exists.
      Maps to T4.
- [ ] Manual (live box, operator): after a rebuild, the client's
      generated pubkey is registered on the edge via one authenticated
      `/signup` (rotation) and `wg show` shows the tunnel up. Maps to T6.

## Smallest version

The client generates + persists its own keypair under
`/var/lib/cococoir/wg-private.key`, brings up `wg0` from a `tunnel` config
section (edge pubkey, endpoint, tunnel IP — all stable, known values), and
starts the forwarder against the now-existing tunnel IP. The NixOS wg0
module is removed. The operator registers the client's generated pubkey
once via `/signup` rotation (the stopgap until a customer-auth device
token exists — ADR-025). Config-driven, so boot does not depend on edge
reachability: wg0 comes up locally, the WG handshake waits for the peer to
be registered.

## Alternatives considered

- **Write the key file by hand** (status quo) — case for: 1 command, box
  back up now. Case against: it is the exact silent-failure seam we are
  removing; a re-provision hits it again. Rejected.
- **Hybrid: NixOS owns interface, client owns key** — case for: boot-stable
  address without a bind race. Case against: still two owners of the
  tunnel, and the forwarder bind race is solved just as well by the client
  sequencing wg0 before the forwarder. User chose full drop. Rejected.
- **Full drop + client self-registers** (complete dashboard-keygen) — case
  for: no operator step at all, true self-heal on re-key. Case against:
  `/signup` is AdminKey-auth'd; a customer box must not hold the admin key,
  and the "website-signup device token" (ADR-025) that would let it
  self-register is deferred. Blocked today. Deferred; the operator
  signup-rotation is the stopgap.
- **Full drop, config-driven (chosen)** — client owns wg0 + key; tunnel IP,
  edge pubkey, endpoint come from config (stable for a registered
  customer), so wg0 comes up locally with no edge reachability dependency.
  Operator registers the key once.

Why the winner wins: it removes the fragility and the operator key-file
step now, with a boot-stable tunnel, and it is the base the device-token
self-registration builds on later — the Rust wg0 ownership does not change.

## Architecture decisions

- **Client owns wg0 + key.** New `cococoir-client` module shells to
  `ip`/`wg` (root unit, `path = [iproute2 wireguard-tools]`), mirroring the
  edge's `RealWgClient`. No new customer-facing options beyond one
  `tunnel` config section.
- **Key persists at `/var/lib/cococoir/wg-private.key`** (0600, under
  `StateDirectory=cococoir` — the one writable path under
  `ProtectSystem=strict`). The client is the sole authority; it never sends
  the private key anywhere (ADR-025).
- **Config-driven tunnel.** `cococoir-client.json` gains a `tunnel`
  section: `{ iface = "wg0", ip = "10.10.0.3", prefix = 24,
  edge_pubkey = "...", edge_endpoint = "62.238.111.21:51820",
  edge_allowed_ips = "10.10.0.0/24", listen_port = 0 }`. The forwarder's
  existing `listen_addr = "10.10.0.3:80"` binds against the interface the
  client brings up. Boot is local + stable.
- **Registration is the operator's one authenticated `/signup`**
  (rotation, idempotent). The client cannot self-register until the
  device-token auth lands; that is deferred and does not block wg0 (the
  handshake waits). Documented operator step, not a key-file write.
- **Boot sequencing:** client brings up wg0 before `Forwarder::new` (which
  binds the tunnel IP), so no bind race and no `wireguard-wg0.service`.

## Tasks

### T1: `cococoir-client` tunnel module (keygen + wg0)
**Depends on:** none — DONE
**Verification:** `cargo test -p cococoir-client` green; idempotency
tests for keypair + interface/addr. L0.
**Files:** `crates/client/src/tunnel.rs`, `crates/client/src/lib.rs`

`ensure_keypair(path)` (read else generate+persist 0600, never
regenerate) + `bring_up_wg0(cfg)` issuing the `ip`/`wg` sequence, each
idempotent. Test the command construction with a mock shell or capture.

### T2: wire tunnel into the client entry point + config
**Depends on:** T1 — DONE
**Verification:** `cargo test -p cococoir-client` green; `ConfigFile`
parses the `tunnel` section; wg0 is brought up before the forwarder
binds. L0.
**Files:** `crates/client/src/app.rs`

Add `tunnel: Option<TunnelConfig>` to `ConfigFile`; on startup, if set,
`ensure_keypair` + `bring_up_wg0`, then build the forwarder.

### T3: client unit — tools on path, drop wg0 dependency
**Depends on:** T2 — DONE
**Verification:** `nix flake check` green; unit renders with
`path = [iproute2 wireguard-tools]` and no `after = wireguard-wg0.service`.
L1.
**Files:** `nix/nixos-modules/client.nix`

### T4: amon-sul — drop NixOS wg0, add tunnel config
**Depends on:** T2 — DONE
**Verification:** `nix eval` shows no `networking.wireguard` and the
tunnel config with `10.10.0.3/24` + edge peer. L1.
**Files:** `nixosConfigurations/amon-sul.nix`

Remove `networking.wireguard.interfaces.wg0`; add the `tunnel` section
(edge pubkey `lX+5lGEF1qDJEag13Kymyxy/SJH63LPxKTvMg50WE2E=`, endpoint
`62.238.111.21:51820`, ip `10.10.0.3/24`).

### T5: L2 edge test — client-owned wg0
**Depends on:** T1, T2 — DONE
**Verification:** `edge-forward` nixosTest passes with the customer box's
wg0 created by the client from its persisted keypair. L1 + L2.
**Files:** `nix/tests/edge/default.nix`

Customer node drops the NixOS wg0 module; the client unit creates wg0 from
its tunnel config + persisted key.

### T6: deploy + register amon-sul (operator)
**Depends on:** T3, T4, T5
**Verification:** after rebuild, the client's pubkey registered via one
authenticated `/signup` rotation; `wg show` shows the tunnel; remote
reachability. Manual.
**Files:** none (live; results into `docs/STATUS.md`)

## Strongest objection

This is a substantial new privileged subsystem (the client shells to
`ip`/`wg` to own a network interface) built while amon-sul is down and I
cannot deploy it (no root). And it is only a *partial* dashboard-keygen:
because `/signup` stays AdminKey-auth'd, the client cannot actually
self-register its key — the "self-healing on re-key" only happens if the
operator runs a `/signup` rotation call, so a re-provisioned box still
needs a human. If a later box forgets that step, it fails exactly like
today. Defense: config-driven wg0 brings the tunnel up locally with no
edge dependency, the forwarder bind race is removed by sequencing, and
the Rust wg0 ownership is the durable base the device-token auth builds on
— the auth gap is a one-line "call /signup" from closing once the token
exists, not a rewrite. The remaining risk is that the client now owns
privileged networking with its own failure modes (duplicate interface,
stale peer); mitigated by idempotency tests in T1.