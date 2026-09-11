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
**shared Floating IPv4 `/32`** (€3/mo); a **Redis leader lease** decides
which node is active; on death the active node's floats are reassigned to
the standby via the Hetzner API (the same client that already does DNS),
and the standby — already hot with all wg peers, forwards, and local
address binds — serves the same addresses within seconds.

## Acceptance criteria

- [ ] **L0** Lease + promotion: with a live Redis pair, the standby
      detects lease expiry (heartbeat TTL), promotes the replica
      (`replicaof no one`), acquires the lease, and calls the float driver
      to move the `/64` + `/32`s to itself. RTO budget asserted
      (lease TTL + move < 10s). Maps to T4.
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
- [ ] **L1** `nix flake check` green, including a new `vmtest-wiring`-style
      tripwire asserting the two-node rendered configs hold the same `wg0`
      key, the same floating `/64` for customer carving, and a Redis
      primary/replica pair. Maps to T3, T5.
- [ ] **live (L2-class)** `remote-infra/scripts/edge-ha-failover-test.sh`
      green against the real pair: hard-kill node A → lease flips → floats
      move to B → a live customer `/128` **and a provisioned `/32`** both
      return 200 and follow the failover → `interdim.net` + the WG dial-out
      endpoint stay up → DNS zone records (A and AAAA) are byte-identical
      before and after → RTO < 15s. Maps to T7. This is the gate; an
      untested failover is fiction.

## Smallest version

Two nodes in one Hetzner location, both running the full edge stack
(control plane + forwarder + `wg0` with the shared key + Redis
primary/replica), customer `/128`s carved from **one** floating `/64`,
one floating `/32` for the WG endpoint + Caddy. Failover driven by the
Redis leader lease + the existing reconcile loop. A live kill-test
script is the gate. Everything else explicitly deferred:

- **Billing / entitlement plumbing for the SKU** (charges, invoices,
  payment-state gating) — accounts-and-pairing is mid-flight; the
  technical provisioning path lands in T6, payment hooks ride later. The
  entitlement flag exists; billing does not.
- **keepalived/VRRP** sub-second upgrade — only if real-world failovers
  feel too slow; the Redis lease is the shipped driver.
- **Cross-location disaster node** (floats move within the network zone
  via API, minutes) — add a third node when the uptime story demands it.

## Alternatives considered

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

Why the winner wins: raw VMs + the existing control plane is this repo's
ethos (no added substrate), and one floating `/64` makes per-customer v6
mobility cost €1/cluster instead of €1/customer. The Redis lease reuses
the store, the Hetzner client, and the reconcile loop already built —
failover becomes the reconcile loop doing what it already does, just
against the float driver.

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
- **Coordination = Redis leader lease, not keepalived.** Key
  `fortress:edge:lease` (node id + TTL heartbeat) in the replicated store.
  The lease holder is Redis primary + active; the standby reconciles to
  replica + ready. Detection = heartbeat interval (TTL 8s, renew 2s),
  inside the RTO budget (relaxed from 10s → **15s**, decided 2026-09-07).
  **Split-brain is bounded, not eliminated:** with one primary + one
  replica, a partition lets the standby's lease copy go stale and both can
  briefly believe they're active. The float assignment at Hetzner is the
  globally-reachable tiebreaker: the active node polls every tick that its
  floats are still assigned to it, and on discovering a loss it **stops
  serving and never re-assigns**. The loser of the last reassignment
  yields; the switchover is bounded and self-healing without a quorum.
- **Shared `wg0` identity.** The edge WG private key becomes a
  store-held secret provisioned to both nodes (security-posture change:
  it replaces per-node self-generation). Both nodes must present the same
  peer identity so a re-handshake to the survivor just works.
- **The store stays on the pair** (replicated), so a node death never
  takes the store or the website; the control plane rides the shared `/32`
  float.
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

### T4: Redis primary/replica + leader lease + promote + float-move
**Depends on:** T1
**Verification:** L0 (live Valkey, like `redis_store_round_trip`): lease
acquire / renew / expiry / promote-on-expiry; on promotion the reconcile
calls the float driver to move the `/64` + `/32`s to the promoted node;
the standby rejoins as replica when the original returns; the
float-ownership reconcile yields when a float is lost; RTO budget
asserted (< 15s). **Design decided 2026-09-07** (sub-spec below).
**Files:** `crates/controlplane/src/controlplane/lease.rs` (new),
`crates/controlplane/src/controlplane/mod.rs`,
`crates/controlplane/src/bin/fortress-edge.rs` (fast lease loop),
`remote-infra/system-manager/edge.nix` (Redis replica config)

#### T4 design
- **Lease.** Key `fortress:edge:lease`, value = node id, TTL **8s**,
  renewed every **2s** by the active node on its own (primary) Redis.
  `lease.rs`: acquire (`SET NX EX 8`), renew (`SET XX EX 8`), release
  (`DEL` guarded by `GET == self`); every op compares against the node id.
- **Detection.** The standby observes the lease through replication: its
  local replica copy stops renewing when the primary dies → expires after
  TTL → promote. No separate heartbeat channel.
- **Promotion.** `REPLICAOF NO ONE`, acquire the lease locally, then the
  reconcile moves the cluster `/64` + shared `/32` to self via the float
  driver (`list` → assign drift), and starts serving.
- **Rejoin.** The original, on return, sees the peer holds the lease +
  floats → `REPLICAOF <peer>`, discards its stale primary data (fresh
  re-sync), becomes standby.
- **Self-configuring boot.** First-to-acquire is primary; the other
  replicates from it. No per-node roles in provisioning — any boot order
  works.
- **Anti-split-brain.** With one primary + one replica, a partition lets
  the standby's lease copy go stale and both can briefly believe they're
  active. The float assignment at Hetzner is the globally-reachable
  tiebreaker: the active node polls every tick (2s) that its floats are
  still assigned to it, and on discovering a loss it **stops serving and
  never re-assigns**. The loser of the last reassignment yields; the
  switchover is bounded and self-healing without a quorum.
- **Loop integration.** `bin/fortress-edge.rs` gains a fast interval
  (2s) driving the lease reconcile; the 2h DNS reconcile is unchanged.
  Each tick: lease held → renew + verify float ownership; expired →
  promote; peer holds it → standby (rejoin/replicate).

#### T4 alternatives considered
- **Sentinel / managed Redis failover** — needs 3 nodes for quorum; the
  pair has 2. Rejected.
- **Deterministic primary at boot** (tofu designates edge-a) — case for:
  predictability. Case against: edge-a-down-at-boot stalls the pair until
  a forced promote; self-configuring handles any order. Rejected.
- **External lock service as fence** — no shared external store exists
  (zero-substrate ethos); the float assignment itself IS the fence —
  whichever node the float is assigned to is authoritative.

#### T4 tasks
- **T4.1** `lease.rs`: acquire/renew/release/is_held, node-id guarded.
  **Verification:** L0 unit tests (SET NX/XX semantics, expiry,
  wrong-owner release refused). **Files:** `lease.rs` (new).
- **T4.2** promote + rejoin orchestration in `mod.rs`: on expiry →
  `REPLICAOF NO ONE` + acquire + reconcile floats; on return → `REPLICAOF
  peer`. **Verification:** L0 with live Valkey (two instances) + mock
  float client. **Files:** `mod.rs`, `lease.rs`.
- **T4.3** float-ownership reconcile: each tick, if active, verify the
  floats are assigned to self via `list`; on loss → degrade (stop serving,
  never re-assign). **Verification:** L0 (mock moves the float away →
  node yields and does not fight back). **Files:** `mod.rs`, `float.rs`.
- **T4.4** fast loop in `bin/fortress-edge.rs` (2s interval) + Redis
  replica config in `edge.nix` (`replicaof` the peer's primary IP — a
  per-node provision value). **Verification:** L1 tripwire (rendered
  configs carry the Redis replica pair — the arc's L1 AC).
  **Files:** `bin/fortress-edge.rs`,
  `remote-infra/system-manager/edge.nix`.
- **T4.5** L0 live-Valkey lease lifecycle test (acquire/renew/expiry/
  promote/rejoin) + RTO assertion (detect ≤ TTL + poll, move ≤ API budget,
  sum < 15s). **Files:** test module in `lease.rs`/`mod.rs`.

#### T4 strongest objection
A **wedged** primary (network stuck, process alive) is indistinguishable
from a dead primary by lease expiry alone: the standby promotes and
reassigns the floats, but the wedged primary still holds the real float
until the reassignment lands, and if the wedge heals mid-move, both fight
— a window where customer traffic flaps. The ownership poll bounds the
yield side but not the promotion side in this case; the honest guarantee
is "promote within TTL + poll" only while replication is healthy. The
gate test (T7) must therefore include a wedged-primary case, not just a
hard kill.

### T5: Two-node provisioning (tofu + system-manager + Cloud Network)
**Depends on:** T2, T3
**Verification:** tofu renders two nodes (edge-a/edge-b) in `hil` on a
Cloud Network with per-node primary IPs + shared floats; the single `edge`
resource is replaced and the `hel1` box retired; both `system-manager
switch` clean; `nix flake check` green including the new tripwires;
`example123` re-provisioned on the pair.
**No Redis data migration (decided):** the hel1 Redis (customers, `/128`
alloc counter) is deliberately NOT carried over — it holds demo/test data
only, so the pair starts fresh in `hil`, the alloc counter resets, and
existing customers re-register (new `/128` + new keypair). Consequence
accepted: the "same address, no DNS" mobility promise applies to failovers
*after* cutover, not to this one-time migration (fresh `/128`s for
everyone). If real (non-demo) customers land on the old edge before T5,
this decision must be revisited (a dump/restore of the Redis store is the
fallback).
**Files:** `remote-infra/tofu/main.tf`, `remote-infra/tofu/render.tf`,
`remote-infra/tofu/variables.tf`

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
against the real pair: hard-kill node A → lease flips → floats move to B
→ a live customer `/128` and a provisioned `/32` both return 200 → 
`interdim.net` and the WG endpoint stay up → A and AAAA records
byte-identical before/after → RTO < 10s. Documented as the tripwire for
any future edge-HA change.
**Files:** `remote-infra/scripts/edge-ha-failover-test.sh`,
`remote-infra/scripts/provision-edge.sh`, `remote-infra/README.md`

### T8: Store backup to S3-compatible object storage
**Depends on:** T4, T5
**Verification:** rendered config carries the snapshot timer + upload
tool; sops holds the S3 creds. Live: a snapshot lands in the bucket; a
documented restore (dry-run on a scratch Redis) reproduces an account.
**Design:** hot-hot covers a node death; backups cover the case it
doesn't — pair loss, datacenter event, or the config-blast-radius taking
both nodes. RPO = timer interval (default 10 min; the store is KBs, so
frequent is ~free). Snapshot the **replica's** RDB (`BGSAVE` on the
standby — zero impact on the serving node, and exercises the replica).
Upload via rclone to S3-compatible storage; Hetzner Object Storage is the
natural fit (same provider, S3 API), but rclone + client-side encryption
make the target provider-agnostic. **Client-side encrypt before upload**
(zero-knowledge: the store holds account emails, hashed passwords, and —
until T3 — the wg0 key). Restore: load the RDB into a fresh Redis,
**scrub the transient keys** (`fortress:edge:lease` + heartbeat state —
restoring a stale lease would confuse the pair), restart the control
plane. What's preserved: accounts, pairing, wg peers, and the `/128` alloc
counter (`fortress:alloc:next`) — restore must never re-allocate customer
addresses. Runbook in `remote-infra/README.md`.
**Files:** `remote-infra/system-manager/edge.nix` (timer + rclone),
`crates/controlplane/secretspec.toml` (S3 creds),
`remote-infra/README.md` (restore runbook)

## Strongest objection

This arc makes the edge **more complex — two nodes, a replicated store, a
shared secret, a lease — to protect against a failure mode that has never
actually happened** to the single box, and its strongest proof (T7) can
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