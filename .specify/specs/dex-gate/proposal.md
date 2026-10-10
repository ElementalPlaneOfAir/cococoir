# Dex forward-auth gate

**Status:** implemented (working tree, uncommitted)
**Date:** 2026-10-10
**Scope:** radarr, sonarr, qbittorrent, the Caddy routing plane

## Premise

The *arrs cannot "log in with Dex" — they have no OIDC support at all, and
their only RBAC is [Sonarr#7186](https://github.com/Sonarr/Sonarr/pull/7186),
a draft that was **locked and never merged**. `AuthenticationMethod=External`
is not an identity mapping either: it is the *same handler as `None`*
(Servarr, Sonarr#5252). Whoever reaches the port gets in.

So the identity has to live in front of the app, not inside it. The gate is
the enforcement point; the app trusts the loopback source.

This was not a hardening exercise. On amon-sul, three of four admin surfaces
were already **LAN-open**: qBittorrent accepted unauthenticated `POST`
torrent writes (`WebUI\LocalHostAuth=false` with no password configured), and
sonarr ran `AuthenticationRequired=DisabledForLocalAddresses`. Only radarr
actually challenged anyone.

## Decision

Caddy `forward_auth` → **oauth2-proxy** → **Dex**. One gate, one Dex client.

Group model (`gate-policy.nix` owns the rule in exactly one place):

| group | grants |
|-------|--------|
| `admins` | implicit member of **every** group — root |
| `arr` | radarr, sonarr, qbittorrent |
| `users` | the household (seerr, jellyfin — not gated here) |

Group policy is **per-request**, not per-instance: oauth2-proxy's
`/oauth2/auth?allowed_groups=<csv>` answers 403 when the caller is in none of
them, so one gate serves every group and each route carries its own policy.

`admins` is appended in code, never written by hand. A second copy of that
rule that forgets `admins` does not fail loudly — it silently locks the box
owner out of their own media stack.

Per-service posture (the app's own auth is *off*):

- radarr / sonarr — `AuthenticationMethod=External`, converged on **every**
  start by `services/_pin-arr.nix`
- qbittorrent — `LocalHostAuth = true` (the value its own comment always
  described; the config said `false`)

`/api` is deliberately **not** gated: Prowlarr and mobile apps authenticate
with `X-Api-Key`, and an HTML login redirect there silently breaks inter-*arr
sync. The API key remains required on every API path regardless of auth
method.

## Alternatives, and the case against each

- **`AuthenticationMethod=Forms` + a sealed password.** Zero new services.
  Against: not Dex, a second credential to manage, and you are back here next
  week. Rejected by the customer.
- **Reuse the fortress dashboard (port 3210) as the auth endpoint.** One
  fewer process. Against: it is a landing page and service catalog, not a
  session store; OIDC session handling is real Rust work and a new
  responsibility for that binary.
- **One oauth2-proxy instance per group.** Simple per-group config. Against:
  N Dex clients, N ports, N cookie names — multiplicative weight for a
  property `/oauth2/auth?allowed_groups=` already expresses.
- **qbt keeps its own login.** Smaller change. Against: two unrelated auth
  systems side by side, and qbt's was the one that was already wide open.

## Strongest objection

**`/api` stays ungated, so the API surface is reachable with no Dex login.**
That is Servarr's documented posture and it is sound — the *arrs require the
128-bit API key on every API path regardless of auth method — but it is a
genuine reduction in depth versus a Forms login, and `radarr.public = true`
with `tls.mode = "acme"` means `/radarr/api` is internet-exposed the moment
the public hostname goes live. The API key is the only thing standing there.
Decided consciously, not discovered.

Second: **Dex and oauth2-proxy move into the critical path for UI access.**
If either is down you cannot log in to radarr at all (the *arrs keep
auto-downloading). Before this, a Dex outage cost you Jellyfin login only.

Third, and the one we built the tripwire for: **`External`/`LocalHostAuth`
means "trust the proxy", so a route that loses its `forward_auth` is not a
degradation — it is an open door.** Same class as the *arr category bug.

## Acceptance criteria

- [x] `nix flake check` green, including `applier-wiring`
- [x] Every service with `accessGroup` renders a `forward_auth` preflight on
      its UI row — **proven to fail** when the gate is removed from
      `rowBody` (builder exits 1 naming the service)
- [x] Every gate group is admitted with the `admins` superset
- [x] `/api` rows are exempt and carry no preflight
- [x] A gated service with dex disabled fails the build (`_contract.nix`)
- [x] A gate group nobody can pass fails the build (`dex-gate.nix`)
- [x] The sealed inventory and the bootstrap generator agree
      (`bootstrapInventory` — this one fired mid-change and caught two
      ungenerated credentials)
- [ ] Live on amon-sul: `/radarr` redirects to Dex, `arr` member gets in,
      `users` member gets 403, `/radarr/api` with `X-Api-Key` still works
- [ ] Live on amon-sul: qBittorrent write from the LAN is refused without a
      Dex session (the exact probe that found it open)

## Notes

- `cookie.secure = false`: the LAN and I2P planes are plain HTTP by design,
  so a Secure cookie would never be sent back. Clearnet still forces HTTPS
  via its 308.
- `cookie.domain = null` (host-only): each plane keeps its own session, so a
  clearnet cookie is never replayed against the I2P surface.
- The OIDC `redirect_uri` is the canonical origin; the per-plane twins are
  registered in Dex so `planeSwapLines` can bring the browser back to the
  plane it started on.
- Customer config grows by two secret declarations (`oidc-gate-secret`,
  `gate-cookie-secret`) and, if a non-admin should reach the *rr stack, one
  word in that user's `groups`. No new toggles.
