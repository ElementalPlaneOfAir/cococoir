# Edge HA — hot-hot pair + floating-IP mobility

Status: proposal.

## Premise

Remote access rides **one Hetzner box** (`edge`, hel1). When it dies —
hardware, kernel, a bad `system-manager switch` — every customer loses
remote access, and recovery today is a manual re-provision whose address
set churns: new `/64`, new `/128`s, DNS rewritten, client caches
compounding the outage for hours (STATUS "Next move" passim).

The paid **IPv4 add-on SKU** (BUISNESS-PLAN `remote access`, ~$5/mo cost
line) needs per-customer public IPv4s anyway, and on Hetzner those are
**Floating IPs** — the *same movable primitive* this HA design needs.
So we build the two-node hot-hot pair + floating-IP mobility now, while
accounts-and-pairing is mid-flight and before billing paints the data
model, and the floating-IP machinery the SKU needs is in place before we
sell it.

If we don't build it: remote access stays single-box (the product's
core feature has a single point of failure), and the revenue SKU has no
infrastructure.

## The property being shipped

**"Same address, no DNS, ~seconds."** A node dies → the customer's public
addresses are *moved*, not re-pointed. DNS never changes, so there is no
cache-staleness class. The residual limit (in-flight TCP blips once) is
accepted by design: the forwarder is stateless (ADR-014), and session
migration would be a stateful LB that violates zero-knowledge.

The mechanism, in one line: customer `/128`s live on a **cluster-owned
Hetzner Floating IPv6 `/64`** (movable, €1/mo) instead of a per-node
auto `/64`; the WG dial-out endpoint + control-plane website live on a
**shared Floating IPv4 `/32`** (€3/mo); a **leader lease on one external
managed Redis** decides which node is active; on death the active node's
floats are reassigned to
the standby via the Hetzner API (the same client that already does DNS),
and the standby — already hot with all wg peers, forwards, and local
address binds — serves the same addresses within seconds.

## Acceptance criteria

- [x] **L0** Lease + takeover: with a live Redis, the standby detects
      lease expiry (heartbeat TTL), acquires the lease from the shared
      store, and calls the float driver to move the `/64` + `/32`s to
      itself. RTO budget asserted (lease TTL + move < 15s). Maps to T4.
- [ ] **L0** Float driver: create/assign/move/release against the Hetzner
      Cloud API wire shape (mock HTTP, same discipline as the DNS client's
      `hetzner_base_is_cloud_api` tripwires); a moved float returns the
      expected server assignment. Maps to T1.
- [ ] **L0** Addressing: every customer `/128` derives from the cluster's
      floating `/64` (never a node's auto `/64`); the forwarder binds it
      (existing `ensure_ipv6_local` path, address family swapped). Maps
      to T2.
- [ ] **L0** IPv4 SKU provisioning: the provisioning path creates a
      floating `/32`, assigns it to the active node, routes it via `wg0`
      to the customer box, and writes the wildcard `A` record;
      de-provision releases it (mock HTTP). Maps to T6.
- [ ] **L0** Identity: the edge `wg0` private key comes from the shared
      secret store and renders identically on both nodes (no
      per-node self-generation). Maps to T3.
- [x] **L1 (partial: store wiring)** `edge-store-wiring` asserts the edge
      template has no local redis, no `--redis-url`, no peer flags; full
      `nix flake check` green (proof 2026-09-11, vermissian). The
      two-node floating `/64`-vs-node-`/64` tripwire lands with T5.
- [ ] **live (L2-class)** `remote-infra/scripts/edge-ha-failover-test.sh`
      green against the real pair: **hard-kill node A** → lease flips →
      floats move to B → a live customer `/128` **and a provisioned
      `/32`** both return 200 and follow the failover → `interdim.net` +
      the WG dial-out endpoint stay up → DNS zone records (A and AAAA) are
      byte-identical before and after → RTO < 15s. **And the wedged-primary
      case (R4):** A stays alive but isolated from B and the API (simulated
      partition) → B promotes on lease expiry → B's float reassignment
      lands → A's float-ownership poll discovers the loss → A stops serving
      and **never re-assigns** → the flap window is bounded by one
      ownership-poll interval and traffic converges to B. Maps to T7. This
      is the gate; an untested failover is fiction.

## Smallest version

Two nodes in one Hetzner location, both running the full edge stack
(control plane + forwarder + `wg0` with the shared key), pointed at **one
external managed Redis** (URL + creds from the operator secret store —
no local Redis on either node), customer `/128`s carved from **one**
floating `/64`, one floating `/32` for the WG endpoint + Caddy. Failover
driven by the leader lease + the existing reconcile loop. A live
kill-test script is the gate. Everything else explicitly deferred:

- **Billing / entitlement plumbing for the SKU** (charges, invoices,
  payment-state gating) — accounts-and-pairing is mid-flight; the
  technical provisioning path lands in T6, payment hooks ride later. The
  entitlement flag exists; billing does not.
- **keepalived/VRRP** sub-second upgrade — only if real-world failovers
  feel too slow; the Redis lease is the shipped driver.
- **Cross-location disaster node** (floats move within the network zone
  via API, minutes) — add a third node when the uptime story demands it.

- **Kubernetes (k3s/k8s) on the pair** — case for: rescheduling, service
  discovery, a "standard" substrate. Case against: the unit of failover
  here is the *node*, not the *process* — hot-hot means no scheduling is
  wanted (rescheduling is a restart; hot is instant). The forwarder binds
  host-local `/128`s and holds long-lived raw sockets; WG is a kernel
  interface; the floats need the host. Every component fights pod
  networking (hostNetwork = the pod is the host = zero abstraction
  value). Redis = StatefulSet + operator + PVCs vs one config line.
  etcd/CNI/kubelet blast radius for two nodes. Rejected.
- **Nomad** — case for: single binary, `raw_exec`, long-running jobs,
  lighter than k8s. Case against: its value proposition is
  scheduling/bin-packing, and the placement rule is "run everything on
  both nodes" — a scheduler is the wrong tool to express that. Rejected.
- **Spin/WASM** — case for: fine for the web-served control-plane API.
  Case against: WG is kernel; the forwarder is long-lived sockets bound to
  specific host IPs; the mobility plane is L2. None of that exists in the
  WASM request-driven execution model. Rejected (confirms the instinct:
  right for HTTP, wrong for the data plane).
- **keepalived/VRRP as the failover driver** — case for: sub-second,
  Hetzner-blessed recipe. Case against: a new subsystem that does one
  thing and cannot be exercised in vmtest (VRRP in QEMU), and its
  split-brain class is no harder to bound than the lease's (both yield to
  the float-ownership tiebreaker). Deferred as an upgrade path.
- **Shared-IP/L7 demux (HAProxy SNI, NAT64, managed anycast fronts)** —
  case for: one cheap IPv4 serves everyone. Case against: a shared front
  must demux by SNI/Host, which forces the edge to learn customer traffic
  (violates zero-knowledge) and breaks TLS-on-device (ADR-006). Rejected.
- **Mesh control planes (Tailscale/Netbird/Headscale)** — case for:
  elegant CGNAT traversal with no public IPs. Case against: a different
  product model (client install on every device, tailnet addressing) vs
  "any browser + wildcard DNS," and the shared-coordination model
  conflicts with per-customer zero-knowledge addressing. Rejected.
- **One floating IPv6 per customer (€1 each)** — case for: no shared /64
  to manage. Case against: €1/customer/mo COGS vs €1/cluster for a /64,
  and the /64 is the same movable primitive. Rejected — the floating /64
  is the whole cost collapse.
- **In-pair primary/replica Redis with promote/rejoin in the edge
  binary** — case for: zero external dependency, no monthly store COGS.
  Case against: built (mid-T4) and it was the wrong shape — the
  coordinator lived *inside* one of the two nodes it arbitrates, so Rust
  had to hand-roll Redis HA (REPLICAOF orchestration, replica-observer
  detection, promote/rejoin, role guards, a 2-node-only boot tiebreak) —
  an unexpandable, hard-to-test distributed state machine — purely to
  work around two stores that cannot agree. One *shared* store makes
  `SET NX` genuinely mutually exclusive and deletes all of it; the data
  plane never touches the store per-packet (the forwarder holds live
  listeners in memory and rehydrates at boot), so the external dependency
  is control-plane-only. Risks stated under Architecture decisions,
  mitigated by URL-in-sops swappability + T8. Rejected after the
  2026-09-11 mid-T4 pivot.

Why the winner wins: raw VMs + the existing control plane is this repo's
ethos (no added substrate), and one floating `/64` makes per-customer v6
mobility cost €1/cluster instead of €1/customer. The lease reuses the
redis client binding, the Hetzner client, and the reconcile loop already
built — failover becomes the reconcile loop doing what it already does,
just against the float driver; the store moving out of the pair deletes
the hand-rolled Redis-HA layer instead of adding to it.

## Architecture decisions

- **New ADR-029 (extends ADR-025/028):** per-customer addresses become
  movable by living on a **cluster-owned Hetzner Floating IPv6 `/64`**,
  with a shared **Floating IPv4 `/32`** carrying the WG dial-out endpoint
  and the control-plane website. The `/64` is the mobility unit;
  failover = reassign floats via the Hetzner API, never touch DNS.
- **Hot-hot pair, raw substrate.** Two cloud VMs in one location, same
  Cloud Network. Both run the full stack; the forwarder stays stateless
  (ADR-014). No container orchestrator — k8s/Nomad/WASM rejected (see
  Alternatives). This is a deliberate "no new substrate" decision.
- **Coordination = a leader lease on ONE shared external managed Redis,
  not keepalived, not in-pair replication.** Key `fortress:edge:lease`
  (node id + TTL heartbeat), TTL 8s, renewed every 2s; both nodes connect
  to the same store URL (secret `REDIS_URL`, TLS `rediss://` from the
  operator store), so `SET NX` is genuinely mutually exclusive — boot
  arbitration IS the lease, first-to-acquire wins; detection = TTL expiry
  inside the RTO budget (relaxed from 10s → **15s**, decided 2026-09-07).
  **Split-brain is bounded, not eliminated:** the float assignment at
  Hetzner is the globally-reachable tiebreaker — the active node polls
  every tick that its floats are still assigned to it, and on discovering
  a loss it **stops serving and never re-assigns**. A leader that cannot
  reach the Hetzner API **self-fences**: it releases the lease so the
  peer can take over immediately rather than waiting out the TTL. The
  switchover is bounded and self-healing without a quorum.
- **Shared `wg0` identity.** The edge WG private key becomes a
  store-held secret provisioned to both nodes (security-posture change:
  it replaces per-node self-generation). Both nodes must present the same
  peer identity so a re-handshake to the survivor just works.
- **The store is external (decided 2026-09-11, mid-T4):** one managed
  Redis shared by both nodes; the pair runs no Redis at all. The data
  plane never touches the store per-packet — the forwarder holds live
  listeners in memory, mutates in-process at signup/delete, rehydrates at
  boot — so the store is control-plane-only state. Honest risks: no SLA
  on a free tier; failover pauses while the store is down (data plane
  unaffected); boot rehydration needs the store; wiping the store means
  customers re-register (accepted). Mitigation: the store is a URL in
  the sops store, so switching providers is a secret change; T8 is the
  provider-independence insurance. The control plane still rides the
  shared `/32` float.
- **Customer IPv4 SKU is in-scope (T6).** A paying customer gets a
  dedicated **Floating IPv4 `/32`** (€3/mo COGS): created on demand by
  the control plane, assigned to the active node, and **routed wholesale
  over `wg0` to the customer box** — opaque, no port knowledge, which
  *strengthens* zero-knowledge and matches the `/128` model. DNS gets a
  parallel wildcard `A` record. Billing/entitlement hooks are deferred;
  the provisioning path is not.
- **Region = `hil` (Hillsboro, OR), decided.** Floats move only within a
  network zone, so the pair is born where it stays; a later region move
  would mean new floats + every customer `/128` changing. The single
  `edge` box in `hel1` is retired (pre-v2, disposable) and `example123`
  re-provisioned on the pair.
- **The pairing payload must push the shared `/32` float as the WG
  endpoint** (not a node primary IP) — coordination with
  accounts-and-pairing T7.

## Tasks

> **Prereq (done 2026-09-07):** the operator provisioning store
> migrated from plaintext `file:` to the age-encrypted **SOPS provider**
> (`secretspec.toml` → `sops://remote-infra/.secrets/secrets.enc.yaml`).
> Both values re-seeded + hash-verified; `provision-edge.sh` unchanged
> (provider-abstracted). T3/T5/T8 write their secrets into this store.

### T1: Hetzner floating-IP client (float driver)
**Depends on:** none
**Verification:** L0 tests against the Cloud API wire shape (create /
assign / move / release, error paths), mirroring the DNS client's
`hetzner_base_is_cloud_api` tripwires; a `float_round_trip` against a
mock server. Live-API behavior is covered by T6, not L0.
**Files:** `crates/controlplane/src/controlplane/float.rs`,
`crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/secretspec.toml` (token scope, if any)

### T2: Addressing moves to the cluster floating /64 + shared /32
**Depends on:** none
**Verification:** `tofu validate` green. tofu adds `hcloud_floating_ip`
(type ipv6 `/64` + type ipv4 `/32`), both created **UNASSIGNED**
(placement is runtime-owned by T4 — tofu pinning a float would fight the
reconcile loop and go stale the first time it moves); `customer_ipv6`/
apex derive from the floating `/64` and the shared `/32`; DNS apex A/AAAA
+ wildcard point at the floats. The tripwire is structural: `local.
edge_ipv6_subnet` defaults to `hcloud_floating_ip.cluster_v6.ip_network`,
so the pre-ADR-029 code path (`hcloud_server.*.ipv6_network`) no longer
exists — a dropped/renamed float fails loudly at plan time instead of
silently carving customers off a node's auto `/64`. The eval-level "pair's
auto `/64`s unused" assertion lands in T5, where a rendered pair config
exists to evaluate.
**Apply ordering:** this config must NOT be applied against the live hel1
box (it would repoint the apex A at an unheld `/32`). The first apply is
the T5 `hil` rebuild.
**Files:** `remote-infra/tofu/main.tf`, `remote-infra/tofu/dns.tf`,
`remote-infra/tofu/variables.tf`

### T3: Shared wg0 identity
**Depends on:** none
**Verification:** the edge `wg0` key is a store-held secret, identical on
both nodes. It flows via `edge.env` (runtime secret), not the rendered
config, so the shared-identity property is (a) structural — one operator
store + one provision script ⇒ both nodes get the same value — and
(b) asserted at L0 (the boot test asserts the installed private key IS the
store-held one and the served pubkey derives from it) and L2 (the vmtest
edge answers as the fixture pubkey, proving `WG_PRIVATE_KEY` in `edge.env`
drives the identity). The per-node self-generation path (Redis
`EDGE_PRIV_KEY`) is removed. The operator key is generated once via
`secretspec`'s `type = "command", generate = { command = "wg genkey" }`
into the sops store (verified stable + valid WG format).
**Also fixed (pre-existing, unrelated to the key change):** the
`edge-forward` L2 test was silently red — nixosTest now assigns
`2001:db8:1::/64` to the VMs' eth1 (edge `::2`, client `::1`), so
(a) the WG endpoint hostname resolved to the edge's IPv6 where the
handshake never got through (endpoint now pinned to the edge's IPv4) and
(b) the client's boot-time handshake was dropped (edge had not yet added
the peer at signup) and WireGuard never re-fired it (the test now
remove+re-adds the peer — a key no-op under the shared identity — to
force a fresh handshake). Proof: `nix flake check` green.
**Files:** `crates/controlplane/secretspec.toml` (`WG_PRIVATE_KEY` contract),
`crates/controlplane/src/controlplane/secret.rs` (`wg_private_key()`),
`crates/controlplane/src/controlplane/mod.rs` (identity from store, no
Redis generation), `secretspec.toml` (operator: `wg genkey` generator),
`remote-infra/scripts/provision-edge.sh` (writes `WG_PRIVATE_KEY` into
`edge.env`), `remote-infra/tofu/templates/edge.nix.tftpl` (comment),
`nix/tests/edge/default.nix` (shared identity + endpoint/handshake fix)

### T4: Leader lease on the shared store + self-fence + float-move
**Depends on:** T1
**Verification:** L0 (live Valkey, like `redis_store_round_trip`): lease
acquire / renew / expiry; on expiry the standby acquires the lease and
the reconcile moves the `/64` + `/32`s to it (mock float client); the
float-ownership reconcile yields when a float is lost (never re-assigns);
wrong-owner renew AND release refused; a leader that cannot reach the
Hetzner API releases its lease (self-fence). RTO budget asserted (< 15s).
**Design pivoted 2026-09-11** to the external shared store (sub-spec
below; the in-pair primary/replica version was built and rejected — see
Alternatives).
**Files:** `crates/controlplane/src/controlplane/lease.rs` (new),
`crates/controlplane/src/controlplane/ha.rs` (new),
`crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/bin/fortress-edge.rs` (fast lease loop),
`crates/controlplane/Cargo.toml` (redis TLS feature)

#### T4 design
- **Lease.** Key `fortress:edge:lease`, value = node id, TTL **8s**,
  renewed every **2s** by the active node — against the ONE shared
  external store both nodes point at. `lease.rs`: acquire (`SET NX EX`),
  renew (**owner-guarded CAS**: `GET` compare, then `SET XX EX`),
  release (`DEL` guarded by `GET == self`); every op compares against
  the node id.
- **Detection.** Both nodes read the SAME key — no replication to
  observe. The standby's tick sees the lease expired (or held) directly.
  No separate heartbeat channel.
- **Takeover.** Lease free (expired) → acquire, reconcile floats to
  self via the float driver (`list` → assign drift), serve. Lease held
  by the peer → standby, never re-assign ("never grabs back"). On a
  fresh pair both race `SET NX`; first-to-acquire is active
  (self-configuring boot, any boot order).
- **Self-fence (the R4 answer).** A leader that cannot reach the Hetzner
  API cannot verify float ownership — and cannot move floats back if the
  peer takes over. It releases the lease (owner-guarded, so it cannot
  drop the peer's) and stands down as standby until the API answers
  again. If it wedges without releasing, the TTL expires naturally and
  the takeover still happens — the fence is fast-path, not the only path.
- **Loop integration.** `bin/fortress-edge.rs` gains a fast interval
  (2s) driving the lease reconcile; the 2h DNS reconcile is unchanged.
  Each tick: floats verified mine → renew; mine-but-renew-refused →
  stand down (never grab back); not mine → try acquire + on success
  move floats; API unreachable → self-fence.

#### T4 alternatives considered
- **Sentinel / managed-Redis failover primitives inside the pair** —
  needs 3 nodes for quorum; the pair has 2, and the fleet-wide managed
  store we now use needs no per-pair sentinel at all. Rejected.
- **Deterministic primary at boot** (tofu designates edge-a) — case for:
  predictability. Case against: edge-a-down-at-boot stalls the pair
  until a forced promote; first-to-acquire handles any order. Rejected.
- **The float assignment alone as the fence** (no lease/Redis) — case
  for: least moving parts. Case against: without the lease, every dead
  node's detection becomes an API poll interval and a fresh pair has no
  arbitration for the initial assignment race; the lease is one key on
  a store we pay for anyway. Rejected — but the float poll stays as the
  tiebreaker, which is what this alternative rightly kept.

#### T4 tasks
- [x] **T4.1** `lease.rs`: acquire/renew/release/is_held/owner, node-id
  guarded; **renew is an owner-guarded CAS** (GET-compare-then-`SET XX` —
  a bare `SET XX` lets a wedged primary resurrect a lease it lost, the
  R4 flapping path). **Verification:** L0 unit tests (SET NX/XX
  semantics, expiry, **wrong-owner release refused AND wrong-owner renew
  refused**). **Files:** `lease.rs` (new). **Done 2026-09-11 (survives
  the pivot; generics collapsed to `ConnectionManager` per a design
  simplification call — production binds the concrete type); proof:
  6 live-Valkey lease tests green under `REDIS_URL`.**
- [x] **T4.2** `ha.rs` reconcile (~80 lines, the pivot's shrink of a 330-line
  state machine): one pass = list floats → all mine → renew (refused →
  stand down); not mine → try acquire (success → move floats to self);
  float `list` fails → self-fence (release if mine, stand down). No
  REPLICAOF, no promote/rejoin, no peer probe, no boot tiebreak — the
  shared lease arbitrates boot. **Verification:** L0 with live Valkey +
  mock float client (expiry takeover moves floats; peer-held lease →
  standby; float lost → yield, no re-fight; API error → fence + release).
  **Files:** `ha.rs` (new).
- [x] **T4.3** fast loop in `bin/fortress-edge.rs` (2s interval) + node
  identity flags (`--node-id`, `--server-id` — NO peer flags; the store
  URL is the shared coordinate). **Verification:** L0 flag validation
  (all-or-nothing); L1 tripwire updated: rendered configs carry the
  external store URL and no local redis service (replaces the arc's
  primary/replica tripwire). **Files:** `bin/fortress-edge.rs`,
  `remote-infra/tofu/templates/edge.nix.tftpl` (redis package/config/
  service deleted; unit no longer passes --redis-url),
  `nix/tests/edge/default.nix`, `remote-infra/system-manager/edge.nix`,
  `remote-infra/scripts/provision-edge.sh` (writes REDIS_URL),
  `secretspec.toml` + `crates/controlplane/secretspec.toml` (contract),
  `secret.rs` (`redis_url()` fallback), `Cargo.toml` (`tokio-rustls-comp`).
  **Done 2026-09-11; proof: L1 `edge-store-wiring` PASS + L2
  `edge-forward` boot test green on vermissian.**
- [x] **T4.4** L0 live-Valkey lease lifecycle test (acquire/renew/expiry/
  takeover) + RTO assertion (detect ≤ TTL 8, move ≤ API budget **5s**,
  sum < 15s). **Files:** test modules in `lease.rs`/`ha.rs`.

#### T4 strongest objection
The coordination point moved outside the pair, which the pair cannot
survive-control-plane-without when it is down: **a store outage pauses
failover and boot rehydration** (the data plane keeps serving, but a
store down while a node dies means the float move waits on the store —
bounded by the store failing, not by our code). A third-party free tier
also carries no SLA and a possible inactivity deletion clause (does not
fire for us: the heartbeat IS the activity), and the reserved lease-key
cleanup on storage restore (T8) matters more when an operator can't
walk to the box. Accepted deliberately: pre-revenue, the store holds
KBs of emails/hashes/pubkeys (no private keys — ADR-025), re-register
is an acceptable wipe story, and the residual is traded away against
deleting a 330-line distributed state machine from the codebase.

hard kill.

### T5: Two-node provisioning (tofu + system-manager + Cloud Network)
**Depends on:** T2, T3
**Verification:** tofu renders two nodes (edge-a/edge-b) in `hil` on a
Cloud Network with per-node primary IPs + shared floats; the single `edge`
resource is replaced and the `hel1` box retired; both `system-manager
switch` clean; `nix flake check` green including the new tripwires;
`example123` re-provisioned on the pair. The external store: `REDIS_URL`
(TLS `rediss://`) lives in the sops store, is written to both nodes'
`edge.env` by `provision-edge.sh`, and neither node runs a local Redis
(the in-box redis service/config are deleted from the edge template).
**No store data migration (decided):** the hel1 Redis (customers, `/128`
alloc counter) is deliberately NOT carried over — it holds demo/test data
only, so the pair starts fresh in `hil`, the alloc counter resets, and
existing customers re-register (new `/128` + new keypair). Consequence
accepted: the "same address, no DNS" mobility promise applies to failovers
*after* cutover, not to this one-time migration (fresh `/128`s for
everyone). If real (non-demo) customers land on the old edge before T5,
this decision must be revisited (a dump/restore of the Redis store is the
fallback).
**Files:** `remote-infra/tofu/main.tf`, `remote-infra/tofu/render.tf`,
`remote-infra/tofu/variables.tf`,
`remote-infra/tofu/templates/edge.nix.tftpl` (no local redis; unit
depends on network, not redis),
`remote-infra/scripts/provision-edge.sh` (writes `REDIS_URL` into
`edge.env`), `crates/controlplane/secretspec.toml` (`REDIS_URL`
contract), `crates/controlplane/src/controlplane/secret.rs`
(`redis_url()` accessor)

### T6: Per-customer floating /32 (IPv4 SKU provisioning path)
**Depends on:** T1, T4
**Verification:** L0 (mock HTTP): provisioning creates the floating `/32`,
assigns it to the active node, adds the `wg0` route `/32` → customer box,
and writes the wildcard `A` record; de-provision releases the float. The
customer-box side (bringing the `/32` up on `wg0`) rides the
accounts-and-pairing pairing payload — coordination noted, endpoint stays
the shared `/32`.
**Files:** `crates/controlplane/src/controlplane/ipv4.rs`,
`crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/controlplane/dns.rs`,
`remote-infra/system-manager/edge.nix` (wg0 route template)

### T7: Live failover test (the gate)
**Depends on:** T4, T5, T6
**Verification:** `remote-infra/scripts/edge-ha-failover-test.sh` green
against the real pair. **Case 1 — hard kill:** node A dies → lease flips
→ floats move to B → a live customer `/128` and a provisioned `/32` both
return 200 → `interdim.net` and the WG endpoint stay up → A and AAAA
records byte-identical before/after → RTO < 15s. **Case 2 — wedged
primary (R4):** A stays alive but isolated from the API (simulated
partition) → A self-fences (releases the lease; if the block is harsh
enough to prevent even that, the lease expires on TTL) → B acquires the
lease and reassigns the floats within
the RTO budget → A's ownership poll discovers the loss → A stops serving
and never re-assigns → the flap window is bounded by one ownership-poll
interval and traffic converges to B. Both cases assert the "never grabs
back" rule. Documented as the tripwire for any future edge-HA change.
**Files:** `remote-infra/scripts/edge-ha-failover-test.sh`,
`remote-infra/scripts/provision-edge.sh`, `remote-infra/README.md`

### T8: Store backup (provider-independence insurance)
**Depends on:** T4, T5
**Verification:** whichever path ships, sops holds its creds; a live run
produces a restorable artifact; a documented restore (dry-run on a
scratch store) reproduces an account.
**Design (amended 2026-09-11 — the store is external/managed):**
hot-hot covers a node death; backups cover the case it doesn't — store
loss, provider deletion (a real clause on free tiers), datacenter
event, or the config-blast-radius killing both nodes. On a free tier
there are no provider backups and no `BGSAVE`, so the first version is
an **edge-side export timer**: `SCAN` + `DUMP` every customer/account
key into a versioned file (the store is KBs — frequent is ~free),
uploaded via rclone to S3-compatible storage, **client-side encrypted
before upload** (zero-knowledge: the store holds account emails, hashed
passwords, and the wg0 key). When the store moves to a paid tier, the
export timer graduates to (or is replaced by) provider-native backups.
Restore: load into a fresh store and restart — the lease key carries a
TTL and cannot be stale; the `/128` alloc counter (`fortress:alloc:next`)
is included, so restore must never re-allocate customer addresses.
Runbook in `remote-infra/README.md`. What this buys: the URL-in-sops
swappability becomes real — if a provider degrades, restores, or bills
hostile, we carry our data out and point `REDIS_URL` elsewhere.
**Files:** `remote-infra/system-manager/edge.nix` (export timer +
rclone), `crates/controlplane/secretspec.toml` (S3 creds),
`remote-infra/README.md` (restore runbook)

## Strongest objection

This arc makes the edge **more complex — two nodes, an external store
dependency, a shared secret, a lease — to protect against a failure
mode that has never actually happened** to the single box, and its
strongest proof (T7) can
only run against the live pair, not in vmtest. Worse: hot-hot identical
nodes share a **configuration blast radius** — a bad Nix eval or a broken
edge module kills *both* nodes at once, which is strictly worse than one
node failing, and no substrate (including this one) fixes that. Defense:
the floating-IP machinery is not pure insurance — it is the exact
infrastructure the revenue IPv4 SKU requires, and that SKU is now *in
scope* (T6), so the cost buys a capability we are actively building, not
hypothetical uptime; the config-blast-radius is mitigated by staged
config rolls (apply to B, watch, then A) and by the control-plane website
surviving a *config* failure as well as a machine one. The residual risks
are honest and stated: the routed-`/32`-over-`wg0` path is new and
unproven until T7; the SKU carries €3/mo float COGS per customer (the
price must clear ~$3.30/mo on the float before covering its node share —
2–3 paying `/32` customers self-fund the whole edge layer); and the first
real proof of failover is the first live run of T7 — that run should be
deliberate and scheduled, not discovered during an incident.