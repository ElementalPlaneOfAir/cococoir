# Proposal: Forgejo service module + Dex OIDC integration

Status: IMPLEMENTED (2026-09-21)
Arc: single slice — a git forge on the platform's 4-option service
contract, auto-wired to Dex the same way jellyfin/cryptpad are.

## Premise

Customers want a private self-hosted git forge. Forgejo is the
lightest genuine forge that (a) runs on SQLite on one box and
(b) can consume Dex as an OIDC provider. Add it as a fortress
service module and wire "enable forgejo" → forgejo + Dex SSO
in one toggle, matching the existing `* + jellyfin-oidc` /
`cryptpad-oidc` pattern. No new customer-facing option beyond
the standard `fortress.services.forgejo.enable`.

## Alternatives considered

- **Gogs** — lighter, but OIDC is still an unmerged PR
  (gogs/gogs#8032, unreviewed as of 2026). No dex integration
  in any release. Rejected.
- **Gitea** — near-identical footprint and OIDC story; Forgejo is
  the community-governed hard fork and the nixpkgs `services.forgejo`
  module is first-class. Gitea's module is a mirror; picking Forgejo
  is a 1-line swap. Chose Forgejo.
- **Soft Serve** — not a forge (no issues/PRs/wiki) and no OIDC.
  Rejected.
- **No SSH for now** — the platform's box already runs sshd on 22 and
  the forwarder owns the tunnel-IP 80/443. Forgejo SSH (built-in or
  via system sshd AuthorizedKeysCommand) needs a port + firewall
  decision that is out of scope for this slice. `DISABLE_SSH = true`;
  git-over-HTTPS with a token is the v1 path. Documented, not silent.

## Design

### Service module (`services/forgejo.nix`)

Standard `mkFortressService` call on the contract factory:

- `name = "forgejo"`, `defaultPort = 3001` (3000 is CryptPad's),
  `defaultHealthPath = "/api/healthz"` (Forgejo's unauthenticated
  health endpoint), `storageNeeded = true`.
- `stateDir = ${fortress.storage.dataRoot}/forgejo` so repos + DB
  land on the auto-declared subvolume (btrfs tier) or under `/data`
  (plain-dirs / container tier — survives container recreate, same
  as jellyfin/cryptpad).
- `services.forgejo.settings.server`: `HTTP_ADDR = "127.0.0.1"`
  (Caddy is the ingress; the forwarder owns the tunnel IP),
  `HTTP_PORT = cfg.port`, `DOMAIN = cfg.domain`,
  `ROOT_URL = https://${domain}/` (Forgejo builds its OIDC callback
  from ROOT_URL), `DISABLE_SSH = true`.
- `service.DISABLE_REGISTRATION = true` — private forge; OIDC users
  auto-register per-source (independent of DISABLE_REGISTRATION,
  verified against gitea issue #26457).
- `session.COOKIE_SECURE = true`.
- btrfs subvolume `forgejo-data` (owner forgejo:forgejo, generous
  quota) + gated `after/requires` on `fortress-btrfs-subvolumes`
  + `RequiresMountsFor` exactly like jellyfin (container-wiring /
  contract-conformance enforce the gate).

### OIDC integration (`integrations/forgejo-oidc.nix`)

Auto-activates when forgejo && dex are enabled:

1. **Secret oneshot** `fortress-forgejo-oidc-secret` — openssl hex
   secret at `/etc/dex/clients/forgejo-secret`, chown root:forgejo.
2. **Dex staticClient** `id = "forgejo"`, redirect URIs =
   `https://${domain}/user/oauth2/dex/callback` +
   `http://${i2pDomain}/user/oauth2/dex/callback`, secretFile.
   The i2p twin lets the dex-module's callback rewrite keep the
   SSO flow on the I2P plane.
3. **Auth-source bootstrap** `fortress-forgejo-oidc-bootstrap` —
   OAuth2/OIDC *sources* live in Forgejo's DB, not app.ini, so the
   dex source cannot be declared in Nix. A oneshot (root, ordered
   after forgejo + dex) runs:
   `runuser -u forgejo -- forgejo admin auth add-oauth
     --name dex --provider openidConnect
     --key forgejo --secret <secret>
     --auto-discover-url http://127.0.0.1:<dex.port>/dex/.well-known/openid-configuration
     --scopes "openid profile email"`
   idempotently (`admin auth list` grep), then `systemctl restart
   forgejo` (auth sources are cached in-process; gitea #8356 class).
   Root runs the oneshot so it can restart forgejo; the CLI itself
   runs as forgejo via runuser so DB WAL files stay forgejo-owned.

The redirect hop to the loopback dex issuer is handled by the
contract factory's generic `issuerLocationRewrite` (every public
vhost) + the dex module's i2p callback rewrite — nothing forgejo-
specific needed for SSO to traverse Caddy.

## Acceptance criteria

1. `fortress.services.forgejo.enable = true` renders forgejo on
   port 3001, HTTP_ADDR 127.0.0.1, ROOT_URL = the clearnet domain,
   DISABLE_SSH, DISABLE_REGISTRATION, SQLite.
2. `contract-conformance` passes with a forgejo row (factory call,
   port, health path, storage tripwire clean).
3. `vmtest-wiring` passes with new assertions: forgejo renders
   enabled from dashboard.nix; dex staticClients has the forgejo
   client with both callback URIs; the bootstrap oneshot is boot-
   activated and orders after forgejo + dex; forgejo's vhost carries
   the dex issuer Location rewrite.
4. `container-wiring` passes (forgejo subvolume renders as a `/data`
   tmpfiles dir, no btrfs refs leak).
5. No new customer-facing option beyond the standard enable.

## Task DAG

- [x] T1: `services/forgejo.nix` module (contract factory)
- [x] T2: `integrations/forgejo-oidc.nix` (secret + staticClient +
      bootstrap)
- [x] T3: import both in `fortress.nix`
- [x] T4: `contract-conformance` forgejo row
- [x] T5: `vmtest-wiring` forgejo assertions
- [x] T6: dashboard.nix toggle + demo-base secret/hosts
- [x] T7: docs (STATUS.md + PLAN.md table)
- [x] T8: `nix flake check` eval verification

## Strongest objection

The auth-source bootstrap is imperative (DB row + service restart)
where the rest of the platform is declarative Nix. On a nixpkgs or
forgejo upgrade the `add-oauth` flags could change and the bootstrap
would fail loudly at boot (acceptable: boot failure, not silent).
More importantly: the bootstrap restarts forgejo on *first* boot,
which delays the forge by a few seconds and could look like a crash
loop in `systemctl status`. Mitigation: the restart happens exactly
once (idempotency grep), forgejo's Restart=always absorbs it, and
the vmtest-wiring assertion pins the wiring so a silently-dropped
bootstrap trips the L1 gate rather than degrading silently.

## Follow-ups (deliberately deferred)

- Forgejo SSH (built-in server on a dedicated port, or system sshd
  AuthorizedKeysCommand) — needs a port/firewall decision.
- Group claim → org team mapping (`--group-claim-name groups` +
  `--group-team-map`) once dex users carry meaningful groups.