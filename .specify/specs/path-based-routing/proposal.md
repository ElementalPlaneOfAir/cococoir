# Path-based routing — one origin per plane

Status: **shipped 2026-09-26** (2026-09-23; T0 audit 2026-09-25; T0.5 client-side
audit 2026-09-25; **scope decision resolved 2026-09-26 — Option A + failover
redirect matrix**, see "Decision record 2026-09-26")

## Decision record 2026-09-26 — the operator chose Option A, amended

Drivers: local usability — with no remote access the catalog must still work at
`http://<lanAddress>/…`. Resolved choices:

1. **Option A (path-capable subset) chosen.** Path-route dex, forgejo, jellyfin,
   radarr, sonarr; Seerr + CryptPad stay subdomain-canonical. The mixed model is
   accepted knowingly; C below softens its cost.
2. **Failover redirect matrix is core, not T9/cut-first (amends A7/A9).**
   `/<name>` is a uniform entry point on *every* plane origin: the non-canonical
   shape of each service answers there and redirects to its canonical —
   `jellyfin.<base>` → `<origin>/jellyfin`, `<origin>/seerr` → `seerr.<base>`,
   and on I2P `/<name>` → `<svc>.<label>.i2p` for subdomain-routed rows. The
   routing mode is a per-service platform fact in the contract (the one place
   that "remembers"); humans and the dashboard just use `/<name>`. Migration
   from subdomains to paths later is a one-line routing flip ("swap the
   redirects") — both shapes stay live.
3. **LAN failover for subdomain-routed services goes to a Caddy port-site**:
   `<origin>/seerr` → `http://<lanAddress>:<seerr-port>`, a `public`-gated Caddy
   site bound to `caddyBindAddresses` proxying the loopback app. Makes the whole
   catalog reachable at the bare IP with zero DNS (the no-remote-access story);
   cost is the service ports in the firewall + one listener per such service.
4. **Redirects are 307, never 301 (amends A7).** 301 caches permanently; the
   routing flip must stay reversible. Explicit code on every `redir`.
5. **T8 (I2P hosts.txt collapse) is descoped** to the i2p-resilience arc; the
   I2P matrix rows derive from the same contract and ship with the factory.
6. **Seerr/cryptpad keep their subdomains, certs, and DNS entries** — the mixed
   model is documented in ADR-034 rather than hidden.

T1 started 2026-09-26 (ADR-034 written; constitution p.1 amended). A landmine
was fixed first: cryptpad (`127.0.0.1:3000`) and the config dashboard both
claimed port 3000 — the dashboard moved to `127.0.0.1:3210` and `client.nix`
now asserts no collision (tripwired in `vmtest-wiring`).

## Premise

Today every catalog service gets its own subdomain (`jellyfin.<machine>.<domain>`,
`auth.<machine>.<domain>`, …) on every access plane. That works because DNS
resolves the names, but it couples three things we want decoupled:

- **I2P** needs one eepsite destination and a `hosts.txt` with N addressbook
  names (see `.specify/specs/i2p-resilience/proposal.md` A7). One name + paths
  is the natural I2P shape.
- **LAN access** requires the box's dnsmasq to be the client's resolver for
  every service name. If resolution fails (the Roku case noted in
  `jellyfin.nix`), nothing resolves — even though the box is one hop away. An
  IP origin with paths needs no DNS at all.
- **The factory** emits one Caddy vhost per service per plane, each with its
  own `issuerLocationRewrite` and its own `i2pDomain`. That is N×planes of
  machinery where 1×plane would do.

The win is a **single origin per plane** — `https://<machine>.<domain>` (clearnet),
`http://<lanAddress>` (LAN), `http://<label>.i2p` (I2P) — with each service at a
path (`/jellyfin`, `/git`, `/radarr`, …). One vhost per plane; one issuer
rewrite per plane; one I2P destination; LAN access by bare IP.

Interview answers (2026-09-23):

- **Why now?** It is cheaper to decide before more services and the I2P layer
  land on the subdomain model.
- **What if we don't build it?** Nothing breaks. This is an optimization, not a
  P0. The cost of not building it is the N×planes machinery above, the N-name
  `hosts.txt`, and DNS-dependence for LAN access.
- **Scope:** full catalog at once (operator decision), **CryptPad deferred** —
  the operator is exploring same-origin sandboxing separately, so it is out of
  this arc, not a standing exception.
- **Cut first if over budget:** the clearnet cutover (keep service subdomains as
  redirects to the path URL; migrate LAN + I2P first).
- **Isolation:** origin isolation (cookies, same-origin policy across apps) is
  explicitly downgraded — the operator judges the box a trusted party for now.
  This proposal does not pretend that is free (see Strongest objection).

## T0 result — app base-path audit (run 2026-09-25)

| Service | On a plane? | Base-path knob | Declarative? | Verdict |
|---|---|---|---|---|
| dex | always (issuer + vhost) | served at `/dex` | yes — issuer path | **GREEN** |
| forgejo | public (optional) | `[server] ROOT_URL` with a path | yes — `services.forgejo.settings.server.ROOT_URL` | **GREEN** |
| jellyfin | public (optional) | `network.xml` `<BaseUrl>`; native, normalized at start, needs restart | no nixpkgs/jellarr option → write `network.xml` in an `ExecStartPre` (radarr pattern) | **YELLOW** |
| radarr | public (media) | `config.xml` `<UrlBase>` | yes — `radarr.nix` already authors `config.xml` in `ExecStartPre` | **GREEN** |
| sonarr | public (media) | `config.xml` `<UrlBase>` | yes — same | **GREEN** |
| seerr | **public (media front door)** | none at runtime; Next.js `basePath` is build-time only | **no** — upstream PR #1411 is an unmerged, conflict-ridden draft | **RED** |
| qbittorrent | **no** — `public=false`, loopback bind, firewall closed | none; PR #21471 closed unmerged | n/a | **OUT OF SCOPE** |
| cryptpad | public | — | — | deferred |

Evidence:
- nixpkgs exposes **no** base-URL option for jellyfin/radarr/sonarr/seerr/qbittorrent.
  `services.seerr` has only `package/enable/openFirewall/port/configDir`;
  `services.qbittorrent` only `serverConfig` freeform — and its
  `WebUI.RootFolder` is the *UI asset directory*, not a URL prefix.
- Jellyfin `network.xml` has a real `<BaseUrl>` (leading `/` added, trailing
  removed, empty = root). jellarr's `base_url` is the *client connection* URL
  (`http://127.0.0.1:8096`), not this — so jellarr cannot set it today.
- `radarr.nix`/`sonarr.nix` already write `config.xml` (including
  `<UrlBase></UrlBase>`) in `ExecStartPre`; the *arrs honor `UrlBase` natively.
- Seerr's live docs: *"Base URLs cannot be configured in Seerr. With this
  limitation, only subdomain configurations are supported."* Its subfolder
  recipe is nginx `sub_filter` HTML/JS rewriting — the silent-failure seam the
  constitution bans.
- Seerr basePath PR #1411: opened 2025-02-28, still a draft as of 2026, merge
  conflicts, and maintainers call it *"severely outdated… brittle… basically a
  hack-around."* Not a foundation to build on.

**Consequence — "full catalog at once" is impossible as written.** Exactly one
customer-facing service is a hard blocker: **Seerr**, and it is the media
stack's front door (the thing customers use most). qBittorrent is not on any
customer plane (loopback, `public=false`), so it is out of scope by
construction. The path-capable set is **dex, forgejo, jellyfin, radarr, sonarr**.

## T0.5 result — client-side base-path audit (run 2026-09-25)

T0 audited whether each *server* can serve under a base path. T0.5 audits the
question T0 left open: does a *client* accept a server address that contains a
path? A server-side `BaseUrl` is worthless if a Roku cannot be pointed at it.

| Client | Accepts `host/path`? | Evidence | Confidence |
|---|---|---|---|
| Jellyfin Web | yes (served by the server at the base URL) | official subpath guides | high |
| Roku | **yes, by design** | `getServerBaseUrl(url, endpointPath)` "preserves any base path (e.g. /jellyfin)", plus `mergePaths` / `resolveUrl` (RFC 3986) / `normalizeUrl` (strips trailing slash except root) — `source/utils/url.bs` | high (source-level) |
| Android / Android TV | yes; needs a **trailing slash** (`host/media/`) | jellyfin-android#544 comment: "would not successfully connect without a trailing / … also the case with the WebOS client" (2021) | medium |
| WebOS | yes; trailing slash required | same comment | medium |
| Swiftfin (iOS/tvOS) | yes; trailing-slash bug **fixed** | Swiftfin#1144: trailing slash doubled `//System/Info/Public` → 404; fixed by #1145 (2024) | high |
| Kodi (JellyCon / Jellyfin-for-Kodi), Infuse | not audited | — | unknown |

**Finding: the official clients are built for base paths; the failure class is
trailing-slash input normalization, not fundamental incompatibility.** The
official Jellyfin reverse-proxy docs state it outright: *"When connecting to
server from a client application, enter `http(s)://DOMAIN_NAME/jellyfin` in the
address field."* (Apache subpath guide.)

Three caveats survive the finding:

1. **Configuration, not redirect.** A client works when it is *configured* with
   the path. A cross-origin redirect from `jellyfin.<machine>.<domain>` to
   `<origin>/jellyfin` still breaks native clients (auth stripped, POST→GET, no
   WebSocket) — so "both URLs work; redirect every time" stays a **browser-only**
   promise. For a pre-customer box with no installed clients this is cheap: the
   client is configured with the path once.
2. **The server half has regressed before.** jellyfin#1979 (10.4.1) and the
   currently-**open** jellyfin#16291 (10.11.6: Base URL 404s even locally) show
   the server side is not rock-solid. Pin a known-good server version and prove
   `curl <origin>/<svc>/` before shipping.
3. **This does not rescue Seerr.** The media front door still cannot be
   base-pathed (T0), so it keeps a subdomain — and therefore keeps DNS on the
   LAN and its own I2P name. Both headline motivations still fail *for the
   most-used service*.

**Residual risk:** this is a documentary audit. No client was empirically
connected to a path-routed server. Before committing to the arc, point a Roku
(the worst case) and an Android phone at `http(s)://<host>/jellyfin` on a
path-routed test box and complete login + playback. That experiment converts
"high-confidence documentary" into proof.

## Open decision (2026-09-25) — **RESOLVED 2026-09-26: Option A, amended** (see
the Decision record above; the analysis below stands as the record of the fork)

"Everything at once" needs re-deciding now that T0 is in:

- **Option A — path-capable subset + Seerr exception.** Path-route dex, forgejo,
  jellyfin, radarr, sonarr; leave Seerr (and qBittorrent, already internal) on a
  subdomain. Cost: a permanently mixed model, and the media *front door* — the
  service customers actually use — still needs DNS on the LAN and its own I2P
  name. That undercuts the two headline motivations for the whole exercise.
- **Option B — kill the proposal, keep subdomains.** The catalog stays uniform.
  The two goals that fail (DNS-free LAN, single I2P name) fail *for the most
  important service anyway*, so the remaining win is narrow. Cost: keep the
  N-name `hosts.txt` and the N×planes machinery.
- **Option C — rebuild Seerr from source with `basePath`.** Technically possible
  (nixpkgs builds Seerr from source), but upstream PR #1411 is an unmerged,
  conflict-ridden draft that maintainers call a hack-around. We would own a
  fragile, version-pinned downstream patch. Rejected on the zero-debt directive
  unless the operator knowingly overrides.

Recommendation: **do not ship Option A** — a mixed model whose main exception is
the media front door keeps the cost and removes most of the benefit. Prefer B
(defer honestly) unless the operator accepts C's maintenance burden.
**T0.5 narrows the reasoning but does not reverse it:** native clients are *not*
the obstacle (they accept base paths); Seerr is. Option A is now a defensible
trade if the operator's driver is single-origin UX, not the LAN/I2P goals —
because those two goals still fail for the media front door.

## Migration options (deferred — investigate if the arc is ever taken up)

If a shipped box ever migrates `svc.machine.domain` →
`machine.domain/svc`, the redirect mechanics need deciding *before* cutover.
Recorded now so the investigation is not lost; **not in scope for this arc.**

- **One canonical base URL per app.** A service cannot cleanly serve at both
  `jellyfin.machine.domain/` and `machine.domain/jellyfin/` — it emits absolute
  paths for exactly one prefix. Migration is therefore a **cutover**, not a
  gradual dual-serve; only the old subdomain's redirect is gradual.
- **Browser-only services** (forgejo, the *arr web UIs): a `301` from the old
  subdomain to `<origin>/<svc>` is genuinely fine.
- **Native-client services** (jellyfin/Roku, mobile apps): a cross-origin
  redirect is **not** enough — most clients strip `Authorization` across the
  hop (401, not a login page), `301`/`302` can turn `POST` into `GET`, and
  WebSocket upgrades (`/socket`) are not followed at all. The fix is
  **re-pointing the client's server address** (re-add, not just re-login).
- **Redirect codes:** trial with `302`; use `307`/`308` if method preservation
  is needed; only commit `301` once certain, because it is cached permanently
  and rollback leaves some clients stuck.
- **Deprecation tail:** keep the old vhosts **and certs** alive as long as the
  redirect must work, and expect a long tail of stale clients.
- **Prefix-rewrite proxy alias** (old host proxies to the app with the prefix
  stripped) is the only way to keep *API* clients alive without re-pointing —
  the same fragile rewrite-against-absolute-URLs mechanism rejected for Seerr.
- **Sequencing:** migrate browser-only services first with `301`; do native
  services as a deliberate cutover plus a documented client re-point step.
  This does not change T0: **Seerr stays on a subdomain regardless.**

## Acceptance criteria

- [x] **A1** `mkFortressService` exposes a per-service `path` (default
      `/<conventionalSubdomain or name>`); the contract's `domain` and
      `i2pDomain` outputs derive from a single per-plane origin instead of a
      per-service host. Proof: `contract-conformance` updated + green (L1).
      Maps to T1, T2.
- [x] **A2** Exactly one Caddy site exists per enabled plane, every enabled
      service answers at `/<name>` on it (proxy if path-canonical, 307 if
      subdomain-canonical), and `/` serves the dashboard. Proof: L1 eval
      asserts the vhost set equals the plane set and each `/<name>` entry
      renders; L2 `curl http://<lan-ip>/jellyfin/` returns the app. Maps to
      T2, T10, T11.
- [x] **A3** Every path-routed service honors its base path (assets and API
      under `/<svc>/` return 200, not 404). Proof: L1 rendered settings present;
      L2 per-service path checks. Maps to T3–T5, T10, T11.
- [x] **A4** Full OIDC login completes on all three planes. Proof: L2
      `bootstrap.sh` runs the authorize → dex login → callback → session flow
      once per plane. Maps to T6, T10, T11.
- [x] **A5** Cookies are path-scoped at the proxy (`Set-Cookie` gains
      `Path=/<svc>`) so services sharing an origin do not collide. Proof: L1
      rendered Caddy config contains the rewrite per service; L2 asserts a
      scoped `Set-Cookie` on a service response. Maps to T6, T10.
- [x] **A6** (descoped to i2p-resilience with T8; the i2p matrix rows derive and ship) I2P is one destination and one name: `hosts.txt` has a single
      label, the dashboard links use paths, and non-path-routed services
      (CryptPad) are marked out-of-scope rather than advertised. Proof: L1
      `hosts.txt` render + L2 dashboard curls. Maps to T8.
- [x] **A7** The failover redirect matrix renders for every catalog service on
      every plane: `/{name}` answers on each plane origin, and each service's
      non-canonical shape 307s to its canonical — never a second copy. LAN
      port-failover: subdomain-routed services 307 to their
      `http://<lanAddress>:<port>` Caddy port-site (public-gated). Redirects
      are **307**, never 301. Proof: L1 matrix assertions per service per
      plane; L2 curl sees 307 + the expected Location on each shape. Maps to
      T2, T9.
- [x] **A8** The L2 gate is green: `scripts/vmtest-e2e.sh` PASS with the new
      routing, and `vmtest-wiring` carries a tripwire for each plane's site and
      each service path. Maps to T10, T11.
- [x] **A9** LAN SSO feasibility determined and documented: **SSO completes
      on the plain-HTTP IP origin** (finding below). Proof: the `lan SSO
      session` check in `vmtest-bootstrap.sh` (full chain on
      `http://<lanAddress>`) + the Secure-cookie audit. Maps to T7.

## Smallest version — **chosen 2026-09-26 (Option A, amended)**

Path-route the path-capable set — dex, forgejo, jellyfin, radarr, sonarr — on
all three planes (Jellyfin via a written `network.xml`; radarr/sonarr via their
existing `config.xml` `ExecStartPre`). Seerr and CryptPad stay
subdomain-canonical, and **every** service gets both failover shapes per A7
(307 matrix, including the LAN port-failover); qBittorrent stays internal.
Ship the loopback-issuer rewrite once per plane, path-scope cookies, and prove
it under `vmtest-e2e.sh`. The I2P `hosts.txt` collapse is deferred to the
i2p-resilience arc. Everything else is explicitly deferred.

## Alternatives considered

- **Keep subdomains (status quo)** — case for: zero per-app work, origin
  isolation for free, contract untouched. Case against: N-name `hosts.txt`,
  DNS-dependence for LAN, N×planes Caddy/rewrite machinery. Rejected by the
  operator for the tech-debt/UX direction, not because it is broken.
- **Path routing on the DNS-free planes only (LAN + I2P), subdomains on
  clearnet** — case for: smallest blast radius, keeps internet-exposed isolation
  unchanged. Case against: an app has one configured external base URL, so it
  cannot be path-routed on I2P while staying subdomain-rooted on clearnet;
  the "hybrid" is global per app in practice. Rejected as incoherent unless
  every app runs twice.
- **One service per port on the LAN IP (`192.168.0.7:8096`, …)** — case for:
  truly zero per-app work, DNS-free. Case against: no single entry point, no
  unified SSO origin, port soup for the customer, and it does not help I2P.
  Rejected as a LAN-only trick, not an architecture.
- **Reverse proxy with HTML/asset rewriting to fake prefixes** — case for:
  works even for qbittorrent. Case against: rewriting a streaming media UI and
  a torrent client's absolute URLs is exactly the "silent failure seam" the
  constitution bans; fragile on every upstream upgrade. Rejected.
- **Make qbittorrent's absence acceptable (mixed model)** — case for: ships
  most of the value. Case against: every mixed model is a second mechanism and
  a second doc. Accepted only as the T0-forced fallback, documented per app.

Why the winner wins: one origin per plane is the only shape that simultaneously
gives DNS-free LAN access, a single I2P destination, and one rewrite per plane;
the per-app cost is real but bounded to a catalog of seven, and it is paid once
per app rather than per app per plane.

## Architecture decisions

- **ADR-034: single origin + path multiplexing — written in PLAN.md
  2026-09-26.** Replaces the per-service-host model. **Amends
  ADR-004/ADR-020's contract**: routing is `path` + a derived per-plane origin,
  with `domain` retained for subdomain-routed services (Seerr, CryptPad) and
  redirect stubs. This was a **constitutional change** (principle 1 named the
  contract as `enable`/`domain`/`public`); the constitution was amended in the
  same change (2026-09-26).
- **Retain the loopback issuer** (`http://127.0.0.1:5556/dex`) with **one
  Location rewrite per plane**, not per service. The issuer is origin-bound and
  one dex serves all planes; path routing reduces the rewrite *cardinality*, it
  does not remove the mechanism. (An origin issuer would fail
  `ValidateIssuerName` when discovery is fetched through a rewritten origin —
  see `jellyfin-oidc.nix`.)
- **Cookie path-scoping at the proxy.** Shared-origin cookie collisions are the
  one concrete bug path; Caddy rewrites `Set-Cookie` to add `Path=/<svc>`.
- **Origin isolation is downgraded, knowingly.** Recorded in the ADR, not
  hidden: one origin means a compromised app shares a browser security context
  with Dex and its neighbours.
- **Supersedes** the per-service `i2pDomain`/N-name `hosts.txt` part of
  `.specify/specs/i2p-resilience/proposal.md` (slice 2); its slice 1
  loopback-issuer work is reused unchanged.
- **No new customer-facing option.** The path derives from the service name
  (constitution 3); the planes derive from `fortress.baseDomain` /
  `fortress.network.lanAddress` / the I2P label.

## Tasks

### T0: app base-path audit (gate) — **DONE 2026-09-25**
**Result:** see "T0 result" above. Path-capable: dex, forgejo, jellyfin
(YELLOW — `network.xml`), radarr, sonarr. Hard blocker: **Seerr** (RED).
Out of scope: qBittorrent (not on a plane). **The scope decision was resolved
2026-09-26** (Option A + failover matrix — see the Decision record).

### T0.5: client-side base-path audit — **DONE 2026-09-25**
**Result:** see "T0.5 result" above. Official clients accept a base path (Roku
proven at source level; docs instruct it); the failure mode is trailing-slash
normalization, not incompatibility. Redirects stay browser-only; Seerr stays
the blocker. **Residual:** no client empirically tested — connect a Roku +
Android to a path-routed box before T1.

### T1: ADR-034 + constitution amendment — **DONE 2026-09-26**
**Proof:** `doc-refs` PASS; ADR-034 in PLAN.md (cited from `_contract.nix`
and `planes.nix`); constitution p.1 amended in the same change.

### T2: routing layer — `path`/`routing` options, per-plane sites, the
failover matrix, cookie scoping, port-sites — **DONE 2026-09-26**
All Caddy rendering moved to a single new `nix/nixos-modules/planes.nix`
(service modules never write vhosts — no merge-order seams). Named
matchers + `route{uri strip_prefix}` rows; 307s both directions;
Set-Cookie `Path=/<path>` on plane proxies; one issuer Location rewrite
per plane + clearnet-callback swaps on the LAN/I2P planes. LAN
port-sites for subdomain-routed services (seerr loopback-forced via
`HOST=127.0.0.1`); `originLocked` (cryptpad) fails over to its hostname.
**Proof:** `vmtest-wiring` matrix assertions + a 23/23 live Caddy smoke
of the rendered config (mock backends: proxy+cookie, catch-all, stubs,
failovers, swaps, port-site) + e2e "Path-routing matrix" block.

### T3: base-path wiring — dex + forgejo — **DONE 2026-09-26**
dex serves at `/dex` (its issuer path; `path = "/dex"` pinned).
forgejo `ROOT_URL` = `<clearnet origin>/git/`; its dex redirectURIs are
the per-plane callbacks. **Proof:** `vmtest-wiring` (ROOT_URL + redirect
matrix) + e2e (dex discovery/token on the plane path).

### T4: base-path wiring — jellyfin — **DONE 2026-09-26**
`network.xml` `<BaseUrl>` pinned in `preStart` (radarr pattern); jellarr
`base_url` + its readiness probe + the OIDC plugin's `ServerBaseUrl` +
the login-button href all carry the path; the plugin's dex redirectURIs
are per-plane. **Proof:** e2e (jellyfin 200 on the plane path, OIDC
button rendered, full SSO flows) + `vmtest-wiring`.

### T5: base-path wiring — radarr / sonarr + internal consumers — **DONE 2026-09-26**
`<UrlBase>` pinned in both `config.xml` writers (sed-on-existing +
heredoc); media.nix's loopback bases, seerr's arr `baseUrl` fields and
Jellyfin `urlBase` all carry the path. **Seerr itself is not
path-routed.** **Proof:** e2e (arr download clients wired through the
pathed API, seerr↔arr↔jellyfin connected).

### T6: OIDC per-plane rewrite + dex redirect URIs + cookie scoping — **DONE 2026-09-26**
The rewrite/cookie machinery shipped with T2's plane renderer (one
issuer swap per plane + clearnet-callback swaps keeping the browser on
its plane); jellyfin/forgejo redirectURIs are the per-plane callbacks
(T3/T4). **Proof:** `vmtest-wiring` + e2e I2P/LAN SSO flows + the
cookie-scoping check.

### T7: LAN plane + SSO feasibility spike — **DONE 2026-09-26**
The spike is automated: `vmtest-bootstrap.sh` walks the full SSO chain on
`http://<lanAddress>` and audits the flow's Set-Cookie headers for
`Secure` flags (curl refuses to send Secure cookies over HTTP exactly
like a browser). Result recorded in A9 below.

### T8: I2P collapse to one destination/name — **DESCOPED 2026-09-26**
Deferred to the i2p-resilience arc (i2pd is not started). The I2P *matrix rows*
derive from the same contract and ship with T2; only the `hosts.txt` collapse
and the dashboard's I2P section wait.
**Files (when taken up):** the i2pd module, `crates/client/src/dashboard/mod.rs`,
the I2P tests in `nix/tests/vmtest-wiring/default.nix`

### T9: failover redirect matrix — **MERGED into T2 (2026-09-26)**
The matrix is a factory concern (every service, every plane, both shapes), not
a separate cut-first slice — see A7 as amended. Redirects are 307; subdomain-
routed services on the LAN plane redirect to their Caddy port-site.

### T10: tripwires — **DONE 2026-09-26**
`vmtest-wiring`: one site per plane, every service row on each, failover
307s both directions, cookie scoping, per-plane issuer rewrites + I2P
callback swaps, seerr port-site + cryptpad originLocked, dnsmasq covers
`baseDomain`. `contract-conformance` pins the routing facts per service.
`vmtest-bootstrap.sh`: the matrix block + I2P and LAN SSO flows + the
A9 Secure-cookie audit.

### T11: full e2e
**Depends on:** T3–T10
**Verification:** `scripts/vmtest-e2e.sh` PASS with all planes exercised.
**L2.**
**Files:** `docs/STATUS.md` (result line)


## A9 finding (T7 spike, 2026-09-26) — LAN SSO works on plain HTTP

The spike is automated (`vmtest-bootstrap.sh` walks the whole SSO chain on
`http://<lanAddress>` and audits every `Set-Cookie` in it). Results:

- **Full OIDC login completes on `http://<lanAddress>`** — plugin authorize →
  dex login → approval → the plane-swapped callback → "Completing
  authentication" (plugin exchanged the code). Same chain proven on the I2P
  plane. The per-plane callback swap keeps every hop on the origin the user
  started from.
- **No `Secure` cookie is load-bearing in the SSO flow** — modern dex carries
  its state in the URL (`req`/`hmac`/`state`), and the jellyfin OIDC plugin
  holds its session server-side. curl (which refuses to *send* Secure cookies
  over HTTP, like any browser) completed every step, so the feared
  Secure-cookie blocker does not apply to SSO.
- **App *sessions* are the remaining caveat.** Apps that mark their own
  session cookies `Secure` (forgejo: `session.COOKIE_SECURE = true`) will not
  hold a session on the plain-HTTP LAN origin — browsers drop `Secure`
  cookies set from non-secure origins. LAN posture: the bare-IP origin gives
  browsing + SSO + every path-routed app; a cookie-session app (forgejo) is
  used over its HTTPS canonical on the LAN (dnsmasq resolves it; no internet
  needed), or its cookies are un-secured by a future option if LAN-only
  sessions become a requirement.
- **Residual (browser-only):** the LAN port-failover for Seerr is a plain-HTTP
  origin; Jellyseerr's session-cookie flags are unverified in a real browser
  (curl accepts them). Point a phone at `http://<lan>/seerr` and log in
  before promising Seerr sessions on the bare IP.

## Strongest objection

T0 turned the objection into a fact: **Seerr — the media stack's front door and
the service customers use most — has no stable base-path mechanism.** Its own
docs say subdomains are the only supported configuration, and the only upstream
path is a draft PR its maintainers call brittle and outdated. So this proposal
cannot deliver "path routing for everything"; at best it path-routes five
services and leaves the most-used one behind *whenever the media stack is on*.
That is precisely the second-mechanism debt the proposal set out to remove.

Second, the headline LAN benefit may be hollow: browsers refuse `Secure` cookies
on a plain-HTTP LAN IP, so offline **SSO** on `http://192.168.0.7` likely cannot
work without a trusted cert (or keeping dnsmasq) — leaving DNS-free *browsing*,
and only for the path-routed services. Third, the blast radius is the whole
product: a contract change, a constitution amendment, and every service module,
against a codebase whose first real-hardware deploy just happened and whose I2P
arc is mid-flight — for an optimization, not a fix. Given the T0 result, the
honest default is **Option B (defer)**; A or C is a knowing trade, not a win.

**Answered 2026-09-26 (the objection stands as the record):** the operator took
the knowing trade — the driver is local usability, which Option A delivers. The
failover matrix (decision 2) answers the first half: `/<name>` is a uniform
entry point on every plane *including Seerr*, so the front door is one extra
hop from the bare IP (via its LAN port-site), not unreachable — the residual
mixed-model debt is a `routing` fact in one place plus Seerr's own cert/DNS.
The SSO half is T7's spike, not a design assumption. The blast-radius half is
accepted: the cutover is per-app and total because base URLs are global.
