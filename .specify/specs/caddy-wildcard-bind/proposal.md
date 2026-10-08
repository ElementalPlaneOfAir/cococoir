# Caddy binds all interfaces; remote ingress decoupled to a second port

## Premise

- **Why now:** the amon-sul cutover died on exactly the explicit bind list.
  `caddyBindAddresses` (localhost + `lanAddress`) meant Caddy bound `127.0.0.1`
  only when the folder's `lanAddress` didn't reach it — LAN unreachable, every
  unmatched host auto-HTTPSed. The list is also why the tailnet (a first-class
  use case) is not a path today: Caddy isn't listening on the tailscale IP.
- **If we don't:** every new interface is a config edit and a silent-failure
  risk; the tailnet stays broken; the localhost-only bind recurs on the next box.
- **The premise the user challenges:** "the bind list is the security model."
  It is not. The firewall already gates 80/443, and Caddy `remote_ip` rules can
  add a per-plane allowlist. The bind list is a second layer that *fails closed*
  — the question is whether that layer is worth its footgun.
- **Cut first if forced:** the tunnel port decoupling. The wildcard bind is the
  felt change; the tunnel isn't runnable on the applier anyway.
- **Smallest felt version:** `curl http://<tailnet-ip>/dex/...` from another
  tailnet node works with zero per-box config.

## Acceptance criteria

- [x] `fortress.network.caddyBindAddresses` defaults to wildcard (`0.0.0.0`, `::`).
      (L1 `vmtest-wiring`: every rendered vhost binds `0.0.0.0 ::`.)
- [x] Caddy answers on a non-loopback IP in `smtest`. (L2: `smtest-e2e.sh`
      curls `http://10.0.2.15/dex` — PASS.)
- [x] The tunnel forwarder listens on a non-80/443 port on the tunnel IP,
      dest `127.0.0.1:{80,443}`. (L0 `edge_forwards_decouple_public_and_client_ports`;
      L2 `edge-forward` PASS — edge public `:80` → client `:8080` → app `:80`.)
- [x] No regression: LAN plane `http://<lan>` + `/dex` still serve
      (`smtest-e2e` PASS); `applier-wiring` still passes.

## Smallest version

Wildcard bind + relax the `127.0.0.1 ∈ caddyBindAddresses` assertion. The
tunnel-port decoupling is a control-plane change (see T3): the edge hardcodes
`for port in [80, 443]` in `allocate`/`rehydrate`/`delete`/`rollback` and
forwards `[ipv6]:{port} → {wg_ip}:{port}` (same port). Decoupling = the edge
binds the **public** port and forwards to a distinct **client** port.

**Decision (2026-10-07):** ship the bare wildcard now with **no** `remote_ip`
allowlist, deliberately, to make debugging easy in the short term. This is
tracked debt, not the end state: the allowlist lands "in the next few
releases" (recorded as an ADR-034 amendment note, not a code TODO). The
strongest objection below is knowingly accepted for that window.

## Alternatives considered

- **Add the tailscale IP to `caddyBindAddresses`** — for: minimal, keeps explicit
  binds. Against: still enumeration; still fails silently on a new interface;
  doesn't meet "just works".
- **Wildcard now, leave the tunnel on :80/:443** — for: smallest. Against: the
  `EADDRINUSE` collision returns the instant the tunnel graduates; shipping a
  latent break.
- **Keep explicit binds + a `bindWildcard` option** — against: a customer-facing
  option for what should be the default (constitution #3).
- **Winner:** wildcard default + decouple the forwarder port. The bind list was
  never the security boundary; its one hard constraint (tunnel ingress) is
  removable at the cost of an edge-side port number.

## Architecture decisions

- **Amends ADR-034**: planes stay per-origin by Host; reachability becomes
  firewall + policy instead of bind address. Add a note to the ADR.
- **ADR-028** (LAN plane) routing unchanged.
- No new ADR. Constitution #3 (no new customer option), #11 (silent-failure
  seam → tripwire).

## Tasks

### T1: wildcard bind default
**Depends on:** none
**Verification:** `nix flake check` — L1 assertion that the rendered Caddyfile
binds wildcard; `applier-wiring` passes.
**Files:** `nix/nixos-modules/network.nix`, `nix/nixos-modules/planes.nix`,
`nix/tests/applier-wiring/default.nix`

### T2: replace the loopback assertion
**Depends on:** T1
**Verification:** L1 — assertion requires the wildcard, not `127.0.0.1`.
**Files:** `nix/nixos-modules/planes.nix`

### T3: decouple the forwarder port (control plane + fixtures)
**Depends on:** none
**Verification:** L0 `edge_forwards_decouple_public_and_client_ports` (asserts
`public != client` and the rendered addresses); L2 `edge-forward` (edge binds
public `:80` → client `:8080` → app `:80`).
**Files:** `crates/controlplane/src/controlplane/mod.rs` (`EDGE_FORWARDS` +
`machine_forward`), `crates/client/src/pairing.rs`, `nixosConfigurations/vmtest.nix`,
`nix/tests/edge/default.nix`, `limonene/archive/amon-sul/config.nix`

### T4: e2e non-loopback bind
**Depends on:** T1
**Verification:** `scripts/smtest-e2e.sh` asserts Caddy answers on the guest's
non-loopback IP.
**Files:** `scripts/smtest-e2e.sh`

## Strongest objection

The explicit bind **fails closed** — a wrong bind is `connection refused`; a
wildcard bind **fails open**. It makes the firewall the *single* thing between
the internet and every service, and a `public = true` service on an interface
you didn't intend (a second NIC, a bridged docker iface, a future wg peer)
becomes silently internet-reachable. The user's "whitelisted IP set inside
Caddy" mitigation is real but is *policy we must now actually write* — it is
not free, and today it doesn't exist. If we take the wildcard, per-plane
`remote_ip` allowlists graduate from "optional hardening" to "load-bearing",
and the firewall's interface scoping becomes a thing a review must check. If
that discipline isn't held, this change lowers the floor rather than raising it.
