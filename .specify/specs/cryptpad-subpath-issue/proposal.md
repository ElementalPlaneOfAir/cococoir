# Upstream issue: opt-in CryptPad subfolder (path-prefix) mode

Status: research complete, issue not yet drafted or submitted
(2026-09-25, from discussion with the operator).

## Premise

The path-based routing refactor (one domain, services under paths —
driven by I2P eepsite administration and LAN access as
`192.168.0.x/<service>` without external DNS) has one hard blocker:
CryptPad. Research question was *"how impossible is it to serve
CryptPad behind a path-based routing endpoint?"* Answer: upstream
documents it as impossible **by design**, and the source confirms it.

Decision from the research: rather than fork CryptPad or maintain a
response-rewriting proxy (both rejected below), **appeal upstream for
an opt-in, documented subfolder mode aimed at single-operator
self-hosting**, and exempt CryptPad from path routing in the fortress
factory in the meantime.

Analysis base: upstream `main` @ `9808cf2` (2026-05-26, v2026.5.1)
cloned to `/tmp/opencode/cryptpad`; fortress runs nixpkgs `cryptpad`
2025.9.0 — same architecture.

## Research findings

### Upstream position (authoritative)

- **Docs (installation, current):** *"CryptPad cannot run in a
  subfolder. Make sure you configure your server to access it through
  the root domain or a subdomain."*
- **Issue [#589](https://github.com/cryptpad/cryptpad/issues/589)**
  ("absolute resource URLs preventing proxy_pass from subdirectory",
  2020, closed) — maintainer `ansuz`: the exclusive-domain requirement
  is *deliberate* (same-origin policy; sensitive crypto on one origin,
  UI in an iframe on another; co-hosted site or CDN script could reach
  account data): *"I'm quite happy with leaving CryptPad unable to run
  in such a configuration as this makes it just a little bit more
  difficult for admins to do the wrong thing."*
- No subfolder feature request exists since; docs warning still live
  in 2026.

### Blast radius (why strip-prefix alone is dead)

| Coupling | Evidence |
|---|---|
| HTML assets | 89 of 93 HTML files root-absolute (`/common`, `/components`, `/customize`); 39 app entry points; ~240 raw `src`/`href` matches |
| RequireJS | `www/common/requireconfig.js` — ~15 root-absolute `paths` + `baseUrl: window.location.pathname` |
| Client JS | 142 non-vendor JS files with root-absolute path strings; 9 `location.href = '/…'` navigations; `www/common/sframe-boot.js:51` regex `^\/(sheet\|doc\|…)` anchored at `/` |
| Server routes | hardcoded (`app.use('/block/')`, `/api/*`, `/ssoauth` in `lib/http-worker.js`) — this half *is* proxy-fixable by prefix strip |
| Config can't carry a path | `lib/env.js:101` — `fileHost: new URL(config.fileHost).origin` (origin-only by construction) |
| Upstream knows | `src/common/outer/login-block.js:127` — *"'block/' here is hardcoded… if we want to make CryptPad work in server subfolders, we'll need to update this path derivation"* |
| SSO plugin (vendored) | `sso-utils.js:18` `callbackURL: config.httpUnsafeOrigin + '/ssoauth'`; `samltoken` cookie `Path=/; Secure` (Secure drops over plain-HTTP LAN) |
| Single-origin-by-config | `httpUnsafeOrigin`/`httpSafeOrigin` baked per instance → `192.168.0.x/cryptpad` fails on origin, not just path (the I2P proposal's cited double blocker) |

### Assets that make the argument (quote upstream back to itself)

- **`docs/example.nginx.conf`** — the production reference runs main +
  sandbox domain in **one `server` block, one process, one cert**:
  *"you'll need to generate a single SSL certificate that includes
  both domains"*; and its comment names where isolation actually
  lives: *"Content Security Policy headers prevent content loaded via
  the sandbox from accessing privileged information"* — i.e. the
  **browser**, not the wire. Upstream's own reference already has the
  proxy holding every key and routing on `Host` inside decrypted
  traffic.
- **`config/config.example.js:68`** — *"in order for the sandboxing
  system to be effective httpSafeOrigin must be different from
  httpUnsafeOrigin."* Soft/configurable, not enforced (fortress
  ships `safe == unsafe`, accepted weakening — `cryptpad.nix:10-13`).

## The argument (final form)

Three claims, in this order:

1. **Proxy layer: no new trust.** Single-box self-hosting already
   terminates every hostname at one proxy holding the certs — per
   upstream's own `example.nginx.conf`. `Host` → `Host + path` is a
   predicate change inside that already-trusted process: no new key
   holder, no new decryption point, no new party who can read
   plaintext.
2. **Browser layer: concede the real cost.** Path co-hosting merges
   CryptPad's origin with co-hosted apps. SOP/CSP are origin-keyed;
   XSS or script injection in any co-hosted app then reaches
   CryptPad's client-side key material (`loginToken` in localStorage —
   `www/common/outer/local-store.js:113`), where today SOP contains
   it. This *is* an effect on upstream's security architecture — say
   so plainly.
3. **The ask: opt-in, documented, scoped.** A `basePath`-style mode
   whose docs state the origin-merge consequence explicitly, aimed at
   deployments structurally unable to get per-service origins: DDNS
   without wildcard DNS, single-destination I2P eepsites, LAN-by-IP.
   Precedent: the config already permits `safe == unsafe`, the same
   class of documented weakening.

### Drafting rules (retracted claims — do not reintroduce)

- **No transport-layer claims.** The draft's HTTP/3 paragraph was
  factually wrong: QUIC Initial keys derive from the client-chosen
  connection ID + fixed salt (anyone passively decrypts them; the
  X25519 share is *inside* the Initial), SNI rides in the first
  flight on TCP TLS too (otherwise virtual hosting couldn't exist),
  and nginx `stream`/`ssl_preread` routes by SNI with zero
  decryption. Path routing *does* require termination — but any
  proxy serving HTTPS terminates anyway, which is the whole point;
  say only that.
- **No "two machines are the only way".** Refuted by upstream's own
  reference config (one process, one cert, both domains), and
  machines don't affect browser-origin isolation anyway.
- **No "almost no effect on security".** Claim 2 concedes the
  effect; the defensible claim is *"no new trust at the proxy layer;
  the only cost is browser-origin sharing, which we ask to make an
  explicit documented choice."*
- **Do not claim path provides isolation.** RFC 6265 §4.1.2.4:
  *"Although seemingly useful for isolating cookies between
  different paths within a given host, the Path attribute cannot be
  relied upon for security."* Web Storage/IndexedDB have no path
  dimension at all; `window.open` gives same-origin DOM access; a
  server-side Referer-prefix ACL is dead on arrival (CryptPad's own
  pages ship `<meta name="referrer" content="no-referrer">`,
  `www/pad/index.html:13`). Argue *scope and opt-in*, never
  equivalence.

### Security-layer notes (from the follow-up review)

- Cookie inventory all fails against a same-origin co-hosted attacker:
  `Path` matches on **request URL** (attacker's `fetch('/cryptpad/…')`
  carries the cookies), `HttpOnly` still yields act-as-user,
  `Secure`/`SameSite`/CHIPS/`__Host-`/`Origin-Agent-Cluster` are all
  keyed above path (site or origin) → moot.
- CORS correction (do not use the draft's analogy): `ACAO: *` is
  **spec-incompatible with credentials** — wildcard never leaks
  cookies; credentialed CORS requires exact-origin echo +
  `Allow-Credentials`. The correct model: cross-origin = gatekeepers
  default-deny; same-origin = no gatekeeper at all. Path co-hosting
  is stronger than an allow-all CORS grant because it deletes the
  cross-origin step. This *supports* claim 2's concession.
- Attacker's requests are indistinguishable from legitimate ones at
  every layer (same connection, Host, Origin, cookies, no referrer) —
  hence "no protocol can fix this": the origin is the platform's only
  security principal, path deliberately excluded.

### Strongest objection (pre-empt it in the issue)

*"My jellyfin instance has an XSS CVE; now it owns every CryptPad
account on the box, and you removed the boundary that contained it."*
Response: yes — that is precisely the documented trade; it is opt-in;
it is scoped to single-operator self-hosting where the operator
already trusts (and already can co-originate) every app on the box;
the alternative excludes whole deployment classes. A maintainer may
disagree with the trade but cannot say we didn't understand it —
that is the bar for the issue not reading as generated text.

## Alternatives considered (fortress side)

- **Response-rewriting proxy** (rewrite HTML/JS/`/api/config` per
  access path) — case for: no fork. Case against: 231+ files of
  rewrite rules, runtime-computed URL semantics unfixable by text
  substitution, every upstream release re-audits the set, corners
  rot silently — a silent-failure seam banned by the constitution
  for a customer product.
- **Fork with `basePath`** — case for: the only *correct*
  path-routed solution. Case against: upstream ideologically opposed
  (#589), crypto suite with security patches we'd now carry,
  rebase tax on every nixpkgs bump — a permanent fork.
- **Architectural exemption (chosen, interim)** — CryptPad stays
  origin-based (subdomain); everything else path-routed. The factory
  needs an internal per-service route style anyway (`"path"` default,
  `"origin"` derived from the service declaration — **not** a
  customer-facing option); any future origin-coupled service
  (Nextcloud, Matrix) hits the same wall. LAN access for CryptPad
  rides ADR-028's per-service dnsmasq enumeration; the I2P
  proposal's CryptPad exclusion stands unchanged.

## Acceptance criteria

- [ ] Issue text drafted using the three-claim structure, checked
      against every drafting rule above.
- [ ] Submitted to `cryptpad/cryptpad`; issue URL recorded in this
      file's Status line.
- [ ] The `routeStyle`/origin-bound exception is carried into the
      path-routing refactor's proposal when that spec is written
      (link added here).

## Next actions

1. Draft the issue (short — the `example.nginx.conf` quote does the
   heavy lifting; RFC quote in the concession paragraph).
2. Operator review against the drafting rules, then submit.
