# edge-l2-e2e — rewrite the edge-forward L2 test for the control-plane edge

## Problem

`nix flake check`'s `edge-forward` check fails to build. It models a **dead
data path**: it enables `services.cococoir-edge` (a NixOS module that was
deleted in `82f2276`; the edge now runs via system-manager) and drives the
edge with a **config file** (`/etc/cococoir-edge.json` + `forwards`) and an
IPv4 per-IP bind. Neither exists anymore: the new `cococoir-edge`
(ADR-025) has no config file, is Redis-driven, binds customer **IPv6
/128s** via `IPV6_FREEBIND`, and reads boot secrets from
`/etc/cococoir/` (secret.rs:31-41 — panics if absent). So the old test
cannot be salvaged by changing one line.

## Goal

Replace `nix/tests/edge/default.nix`'s `edge-forward` with a test of the
**real** edge data path, configured the way production configures it
("around system-manager"): the edge binary run by a systemd unit
replicating `remote-infra/system-manager/edge.nix`, backed by Redis, with
boot secrets present. The test drives a real **`POST /signup`** (bearer
auth), then proves the full path:

```
curl (edge, to its own customer /128 via a lo route)
  -> cocococoir-edge forwarder, [2001:db8:1::2]:80 (IPV6_FREEBIND bind)
    -> WireGuard tunnel (10.10.0.0/24)
      -> cocococoir-client forwarder, 10.10.0.2:80 (wg0)
        -> 127.0.0.1:80 (python3 http.server, Caddy stand-in)
```

## Decisions

- **The edge node runs the binary directly** (systemd unit mirroring
  `edge.nix`), not a NixOS `services.cococoir-edge` module. Redis via
  `services.redis`; `wg0` via `networking.wireguard`; `wireguard-tools`
  installed (the `RealWgClient` shells out to `wg set wg0`).
- **Boot secrets are written into the test VM** (`/etc/cococoir/`
  `secretspec.toml` + `edge.env`) with the five required values, so
  `init_globals`/`SECRETS` resolve. `DNS_*` are throwaway (DNS is
  non-fatal + reconcile-logged); `ROOT_DOMAIN=edge-test.local`;
  `ADMIN_KEY_HASH` = sha256("test-admin-key") =
  `944650a7cd0f9e14d5c4fb15edbffb7fa45fb9ed36a4fa9be3d7e5476ae51bd9`.
- **The client node is wired dynamically in the testScript**, not at boot:
  the client's `wg0` private key only exists after `/signup` returns it.
  So the client boots with just the `python3` stand-in; the test brings up
  `wg0` (signup key) then starts the client forwarder unit. The client
  forwarder is a hand-rolled systemd unit (`wantedBy = []`, started
  manually) so ordering is deterministic and there is no bind-race.
- **Data-path source is a loopback route**, not the internet: the test adds
  `ip -6 route add 2001:db8:1::2 dev lo` on the edge so its own FREEBIND
  `/128` socket is reachable. Two-node nixosTest has no IPv6 transit
  between VMs; the honest claims are: real forwarder, real `/128` FREEBIND
  bind, real WG tunnel, real client forwarder — only the curl's origin is
  localhost instead of the provider's uplink. Noted in the test header.
- **Verification of the forwarder /128 bind** goes through `/status` on the
  edge (`127.0.0.1:9090`) before the curl, so a bind failure is diagnosed
  distinctly from a WG failure.

## Acceptance criteria

1. `nix flake check`'s `edge-forward` check **builds and passes**, booting
   both VMs, doing a real `/signup`, and returning the HTTP fixture over
   the real WG tunnel.
2. The edge runs the `cococoir-edge` binary with the system-manager flag
   shape (`--subnet /64 --wg-subnet --redis-url --api-addr --health-addr`),
   backed by Redis, with boot secrets present — not a NixOS edge module.
3. The test asserts: edge `/status` shows the bound `[2001:db8:1::2]:80`
   forward; the `/signup` response round-trips a customer whose `/128` is
   reachable end-to-end; health endpoints respond.
4. The obsolete config-file/IPv4 framing is gone from the test and from
   `nix/tests/default.nix`'s header comment.

## Out of scope (documented, not fixed here)

- `example123` placeholder (user: being deleted with the signup flow).
- A production-faithful "curl from the internet" variant (needs IPv6
  transit between VMs — deferred; the demo arc is the home for a
  provider-level e2e).

## Task DAG

- **T1**: Rewrite `nix/tests/edge/default.nix` to the control-plane edge
  (edge node: systemd unit + Redis + secrets + wg0 + wireguard-tools;
  client node: python stand-in + manual forwarder unit).
- **T2**: Pass `cococoirPkg` into the test from `nix/tests/default.nix`;
  update that file's header comment (drop Go-era `192.168.1.10` framing).
- **T3**: Verify — `cargo test` still green; `nix flake check`
  `edge-forward` builds + boots (needs `/dev/kvm`).
- **T4**: Docs — STATUS.md (edge-forward moves Broken→Works with this
  proof), proposal task section, `nix flake check` status note.

## Strongest objection

A 2-node nixosTest with **dynamic cross-VM WG wiring** (the client's key
comes from a runtime signup) is the least deterministic kind of test in the
suite: signup timing, WG handshake, and FREEBIND routing all have to line
up, and a failure is hard to attribute. It will be slow (~a real build +
two boots) and possibly flaky, and its "curl to localhost via a lo route"
is not the true internet path. The counterweight: this is the only check
that exercises the actual signup→`/128`→WG→box data path with real kernel
interfaces — the L1 tripwire (vmtest-wiring) and L0 unit tests (incl.
`freebind_binds_non_local_ipv6_address` and `redis_store_round_trip`)
cannot. The old test's premise (config-file IPv4 edge) is gone, so the
choice is this test or none.

## Status (2026-08-23)

All tasks done. `nix build .#checks.x86_64-linux.edge-forward` →
**PASS** (the full signup → `/128` → WireGuard → box data path, over
real kernel interfaces). The other checks stay green (`forwarder-unit-tests`,
`doc-refs`, `contract-conformance`, `vmtest-wiring`). The only `nix
flake check` failure is the pre-existing `example123` nixosConfiguration
(empty storage; it is being deleted with the signup flow). STATUS.md
updated: `edge-forward` moved Broken → Works with this proof.