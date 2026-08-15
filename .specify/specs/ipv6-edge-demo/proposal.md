# IPv6 edge demo — 24h live deployment for collaborator demo

Status: proposed 2026-08-15.

Session 2026-08-15: user interview. Decisions made:
- Goal: a **working demo in 24h** for collaborators, not a production
  deployment. Money is fine to spend. Demo must show the **IPv6
  per-customer edge** vision (`writing/human/architecture_of_ipv6.md`):
  one edge box, a pool of IPv6 addresses, per-customer AAAA records,
  blind L4 forwarding over WireGuard, Caddy on the customer box doing
  real ACME certs.
- Customer box = the existing **home machine, which runs NixOS**.
  It will run `cococoir-client` + Caddy + Jellyfin + Dex (the v2 stack),
  dialing out over WireGuard from behind CG-NAT. This is the "homelab
  server behind ipv4 cgnat" from the vision doc.
- Edge box = **Hetzner cx22 @ nbg1 (~€4.4/mo)**. Hetzner gives every
  server a routed `/64` IPv6 subnet for free — that is the 64–256
  address pool. **No first-party NixOS image exists** (confirmed via
  Hetzner changelog 2026-08): the box boots a disposable `ubuntu-24.04`
  and **nixos-anywhere** installs NixOS from the flake config over SSH
  (the canonical Hetzner+NixOS path).
- **All provisioning is OpenTofu**, in `remote-infra/`. One `hcloud`
  provider with one HCLOUD_TOKEN manages the server, firewall, ssh key,
  AND DNS (Hetzner's DNS API is GA and covered by the same token). The
  NixOS machine configs are *rendered* from tofu templates, so the
  deployed addressing has one source of truth.
- **Secrets never in git.** Token comes from the `HCLOUD_TOKEN` env
  var; WG private keys are generated into `remote-infra/.secrets/`
  (gitignored) and scp'd to the boxes. Only IPs + WG public keys land
  in the rendered (checked-in) configs — public data is fine to commit.
- DNS: `interdim.net` (user-owned, no Hetzner zone yet). The zone is
  created by tofu; the operator points the domain's NS records at
  Hetzner's nameservers. A records → edge IPv4;
  `*.example123.interdim.net` AAAA → one of the edge's IPv6 `/128`s.
- The P0 jellarr gate (`vmtest-e2e.sh`) is **required** for the demo
  (Jellyfin + Dex OIDC is what we show). It is SUSPECTED fixed but not
  proven; the local machine OOMs running the e2e VM, so the P0 proof
  runs on a different machine. This proposal does not re-fix P0; it
  must be proven green before demo day.

## Premise

The vision doc describes a network where each customer gets their own
IPv6 address on a shared edge box, DNS maps `*.<username>.interdim.net`
to that address, and the edge blindly forwards everything received on
the address over WireGuard to the customer's box. Caddy on the customer
box terminates TLS and obtains real ACME certs because the challenge
traffic is forwarded along with everything else. Cellular (IPv6-native)
clients reach the box directly; IPv4 LAN clients use a custom DNS server
and get the same cert.

The v0 `cococoir-edge` forwarder is **already protocol-agnostic**:
`listen_addr` is an opaque string handed to `TcpListener::bind(&str)` /
`UdpSocket::bind(&str)` (retry.rs:73-89), which parses `[2001:db8::1]:443`
bracket-notation IPv6 natively. No Rust changes are needed. The edge
module already documents that "adding the IPs to local interfaces
remains an operator responsibility" (edge.nix:18-19) — that is the gap
this proposal fills with NixOS interface config.

This proposal delivers the deployment: two NixOS configurations in the
repo (edge + customer), the provisioning path, the DNS records, and the
end-to-end verification. It does not change the forwarder, the modules,
or the customer-facing config surface.

## Acceptance criteria

- [ ] **Live edge box** on Hetzner (cx22 @ nbg1) running NixOS, with:
      one public IPv4, a routed `/64` IPv6, a handful of `/128`s bound
      to the interface, `cococoir-edge` running with one forward per
      customer `/128` (TCP `:80` + `:443`), and a WireGuard server.
- [ ] **Live customer box** (home machine, NixOS) with `cococoir-client`
      listening on the WG tunnel, Caddy terminating TLS for
      `jellyfin.example123.interdim.net` etc., Jellyfin + Dex + the
      OIDC integration up, WG dial-out to the edge (works from CG-NAT).
- [ ] **DNS**: `interdim.net` A → edge IPv4; `*.example123.interdim.net`
      AAAA → one edge `/128`.
- [ ] **Real ACME certs**: Caddy on the customer box serves
      `https://jellyfin.example123.interdim.net` with a valid Let's
      Encrypt cert obtained through the tunnel (blind ACME forwarding).
- [ ] **IPv6 path proven**: from a cellular client (IPv6-native),
      `https://jellyfin.example123.interdim.net` loads through
      edge → WG → customer Caddy → Jellyfin with Dex login.
- [ ] **IPv4 LAN path proven**: same hostname from an IPv4-only LAN
      client resolves via A record + local DNS and serves the same
      (IPv6-acquired) cert.
- [ ] **P0 gate green** on a capable machine before demo day:
      `vmtest-e2e.sh` PASS (Jellyfin + Dex + CryptPad + btrfs + sops).
- [ ] **Tripwire**: the IPv6 bind path is covered by a test so it
      cannot silently regress (L1/L2 — see T5).

## Smallest version

An OpenTofu project in `remote-infra/` + two rendered NixOS configs:

1. `remote-infra/tofu/` — server (cx22@nbg1), firewall, ssh key, the
   interdim.net zone + A/AAAA records, and the render step that turns
   `templates/edge.nix.tftpl` + `templates/example123.nix.tftpl` into
   the checked-in NixOS configs with real addressing.
2. `remote-infra/nix/edge.nix` — imports the cococoir modules,
   disables storage + services (edge-only), enables `cococoir-edge`,
   assigns a set of `/128` IPv6 addresses derived from the `/64` to the
   interface, defines the WireGuard server, and generates
   `/etc/cococoir-edge.json` with one forward per customer `/128`
   (`:80` + `:443` tcp → customer WG IP).
3. `remote-infra/nix/example123.nix` — the customer box: full v2
   stack (Caddy, Jellyfin, Dex, btrfs storage, sops-nix) + WireGuard
   client + `cococoir-client` forwarding the tunnel's `:80`/`:443` to
   `127.0.0.1:80`/`127.0.0.1:443` (Caddy). TLS mode `acme`.
4. Provisioning: `scripts/provision-edge.sh` — gen WG keys → `tofu
   apply` → `nixos-anywhere` → scp the edge WG private key.
5. DNS: the zone + records are created by tofu; the operator points
   interdim.net's NS records at Hetzner's nameservers at the registrar.
6. `remote-infra/scripts/demo-verify.sh` — asserts the data path end
   to end (curl via AAAA from an IPv6 client; curl via A + local DNS
   from an IPv4 client; cert chain valid; Dex discovery reachable).

## Alternatives considered

- **Wait for OPNsense + global IPv6 at home** — case for: the real
  product. Case against: no hardware yet, no SLA; the 24h demo is now.
  Rejected for this arc (still the v3+ plan).
- **Free PaaS (Fly.io, Oracle Free Tier, etc.)** — case for: $0.
  Case against: the demo needs a *routed IPv6 pool + per-address
  binding + NixOS*; only a real VPS with a routed `/64` (Hetzner,
  Oracle, Vultr) offers that. Hetzner was picked over Oracle free
  tier for reliability (Oracle free ARM instances get reclaimed, IPv6
  config is more fiddly) and over Vultr for the first-party DNS +
  the repo's existing Hetzner prior art (`v1/tunnel/terraform`).
  Winner: Hetzner.
- **First-party NixOS image vs nixos-anywhere** — Hetzner ships no
  first-party NixOS image (confirmed via Hetzner changelog, 2026-08:
  Ubuntu/Fedora/Debian/etc. only). The box boots a disposable
  `ubuntu-24.04` and **nixos-anywhere** installs NixOS from the flake
  over SSH. This is the canonical Hetzner+NixOS path (NixOS wiki) and
  keeps the whole edge definition in one flake. Alternative rejected:
  manual ISO install via the Hetzner console (out-of-band, not
  reproducible, hard to re-run).
- **`hcloud` CLI one-shot vs OpenTofu for everything** — the user
  asked for OpenTofu so the deployment is declarative and modifiable.
  One `hcloud` provider (>= 1.56) covers the server AND DNS via the
  GA DNS API with a single HCLOUD_TOKEN — no separate hetznerdns
  provider, no second token. The NixOS configs are *rendered* from
  tofu templates so addressing has one source of truth. Winner:
  OpenTofu.
- **Per-customer IPv4 instead of IPv6** (ADR-016's original v3 model) —
  case for: matches the shipped v0 test (which uses IPv4 per-IP binds).
  Case against: IPv4 costs money per address on Hetzner and the user's
  vision is explicitly IPv6. The forwarder handles both families; this
  demo picks the one the customer wants to show. Not rejected, deferred.
- **Use the v1 rathole tunnel** — case for: already built. Case
  against: rathole is TCP-level and the v1 stack is frozen; the v0
  forwarder is the product and the demo must show *it*.
- **Customer box = second VPS** — case for: no home-network variables.
  Case against: user explicitly chose the home machine, and the
  "behind CG-NAT over WireGuard" story is the interesting part. The
  second-VPS path remains the fallback if the home box can't be
  reached on demo day.

## Architecture decisions

- **No Rust changes.** The forwarder binds any `listen_addr` string;
  IPv6 works today (verified in retry.rs:73-89 and forwarder.rs:282).
  If the live demo reveals an IPv6-specific bug, that is a P0 fix in
  this arc, not a refactor.
- **Hetzner `/64` is the address pool.** Hetzner routes a `/64` to
  every server. We bind a small set of `/128`s from it (one per
  customer for the demo; a handful total). Auto-provisioning of
  addresses/DNS is explicitly deferred (the vision doc says so) —
  static Nix for this demo.
- **One forward per customer, per port.** The forwarder model is
  `listen_addr` per forward. Customer `example123` gets two forwards
  (`[ipv6]:80` tcp → `10.10.0.2:80`, `[ipv6]:443` tcp →
  `10.10.0.2:443`). This is the exact shape the edge-forward test
  proves, just IPv6.
- **DNS wildcard → single `/128`.** `*.example123.interdim.net` AAAA →
  the customer's `/128`. Caddy SNI-routes per service on the customer
  box, so one address serves all subdomains. Matches the vision doc.
- **`networking.hosts` on the customer box** resolves `*.example123
  .interdim.net` locally for the IPv4 LAN path (the "custom DNS
  server" from the vision), and Caddy serves the same cert because
  the cert is name-based, not address-based.
- **No new customer-facing options.** The edge + customer configs live
  in `remote-infra/` as rendered NixOS configurations (referenced by
  the flake like vmtest), not as new `cococoir.*` options. The v3
  control plane stays the place where per-customer provisioning
  becomes a product feature.
- **Secrets policy.** Token: env var only. WG private keys: generated
  into `remote-infra/.secrets/` (gitignored), scp'd to the boxes. WG
  public keys + IPs: rendered into the checked-in NixOS configs
  (public data, committed — the user explicitly allowed gitignored /
  SOPS'd secrets, and public keys need neither).
- **The e2e VM does not run on this machine.** The local box OOMs on
  the nixosTest build+boot (7.1GB RAM, ~1.3GB free). P0 proof runs on
  the Hetzner edge box or the customer box before demo day, not here.

## Tasks

### T1: OpenTofu provisioning (edge box + DNS + rendered NixOS configs)
**Depends on:** none
**Verification:** `tofu validate` passes; `tofu plan` (with token)
creates the server + firewall + ssh key + DNS zone + records; the
rendered `remote-infra/nix/*.nix` evaluate in the flake.
**Files:** `remote-infra/tofu/*.tf`, `remote-infra/tofu/templates/*.tftpl`,
`remote-infra/nix/*.nix`, `flake.nix`, `remote-infra/.gitignore`
- [x] DONE 2026-08-15: `main.tf` (server cx22@nbg1, firewall, ssh key,
      `cidrhost`-derived `/64` + customer `/128`), `dns.tf` (zone +
      A/AAAA/AAAA-wildcard rrsets), `render.tf` (renders both NixOS
      configs from templates), `versions.tf` (hcloud >= 1.56 + local),
      placeholder NixOS configs checked in so the flake evaluates
      before provisioning. `tofu init` + `validate` green; both flake
      configs eval.

### T2: WireGuard key generation + provision script
**Depends on:** T1
**Verification:** `scripts/gen-wg-keys.sh` idempotently writes
`.secrets/wg/{edge,customer}.{private,pub}`; `provision-edge.sh` chains
gen-keys → tofu apply → nixos-anywhere → scp edge private key.
**Files:** `remote-infra/scripts/gen-wg-keys.sh`,
`remote-infra/scripts/provision-edge.sh`, `remote-infra/README.md`
- [x] DONE 2026-08-15: scripts written; private keys land in gitignored
      `.secrets/`, public keys flow through tofu into the rendered
      configs.

### T3: provision the Hetzner edge box (blocked on token)
**Depends on:** user's Hetzner API token at
`/home/nicole/.secrets/HETZNER_API_KEY` + `scripts/gen-wg-keys.sh` (needs
`wg`)
**Verification:** `bash remote-infra/scripts/provision-edge.sh` exits 0;
`ssh root@<edge-ip> ip -6 addr` shows the bound `/128`s; nixos-anywhere
install completes; edge WG private key lands at
`/etc/wireguard/edge-private.key`.
**Files:** none (operator action + `remote-infra/scripts/provision-edge.sh`)

### T4: point interdim.net at Hetzner DNS + verify records
**Depends on:** T3 (zone created with real nameservers)
**Verification:** at the registrar, set interdim.net's NS records to
`tofu output nameservers`; `dig AAAA jellyfin.example123.interdim.net`
returns the customer `/128`; `dig A interdim.net` returns the edge IPv4.
**Files:** none (registrar panel + `dig`)

### T5: IPv6-forward tripwire (test)
**Depends on:** none (pure Rust test)
**Verification:** `cargo test` — a unit test binds a loopback IPv6
`[::1]:<port>` through `retry_bind_tcp`, plus a forwarder integration
test over an IPv6 listen address; both prove the IPv6 bind path can't
silently regress.
**Files:** `nix/packages/cococoir/src/retry.rs`,
`nix/packages/cococoir/src/forwarder.rs` (test modules)
- [x] DONE 2026-08-15: `bind_ipv6_loopback_works` (retry.rs) +
      `run_tcp_forward_ipv6_listen` (forwarder.rs). `cargo test` 98/98.

### T6: demo verification script
**Depends on:** T1–T4
**Verification:** run `remote-infra/scripts/demo-verify.sh` from an
IPv6-native and an IPv4 client; all assertions pass.
**Files:** `remote-infra/scripts/demo-verify.sh`
- [x] DONE 2026-08-15: script written (DNS AAAA/A, LE cert chain, Jellyfin
      health, Dex discovery, "Sign in with Dex" button, IPv4 LAN path).

### T7: P0 gate proof on a capable machine
**Depends on:** none (separate from the demo deploy)
**Verification:** `vmtest-e2e.sh` PASS on the edge box or customer box.
**Files:** none (runner + verification; jellarr P0 fix is STATUS.md's
existing suspected-fix, verified here).

## Strongest objection

The demo proves a network topology, not a product. The edge + customer
configs are bespoke NixOS files, the DNS records are static, and the
auto-provisioning the vision doc cares about is explicitly deferred —
so a collaborator watching the demo could reasonably say "this is a
hand-built WireGuard tunnel with extra steps, not a scalable system."
That is true, and it is the honest state: this arc is a **proof of the
address-per-customer forwarding model**, the v3 control plane is the
thing that turns it into a product. The demo's job is to make the
forwarding model tangible (real certs through blind forwarding,
cellular IPv6 reachability, one box many customers), not to fake v3.
Second-order risk: the home box behind CG-NAT is the fragile link — if
its ISP blocks the WG port or the machine is unreachable on demo day,
the whole data path dies. Mitigation: keep the second-VPS fallback in
mind, and prove the CG-NAT path works a day before the demo.
