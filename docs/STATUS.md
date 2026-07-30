# Status

Where the project is *right now*. The living layer of the docs —
PLAN.md says what we're building, this file says what actually
works today. Rules (from AGENTS.md § Context System):

- Every "works" claim names its proof (an L1 check or an e2e run).
  Claims without proof are debt.
- Update this file in the same commit that changes reality.
- Stay under ~80 lines. History belongs in `git log`.

Last e2e: FAIL — 2026-07-29 — jellarr ECONNREFUSED on fresh boot (see P0 below)
(`scripts/vmtest-e2e.sh` rewrites this line on PASS.)

## Works

- v0 L4 forwarder Go unit tests — L0 check `forwarder-unit-tests`.
- edge ↔ client over WireGuard — L2 check `edge-forward` (nixosTest).
- storage layer (Garage + FUSE + sops) — L2 check `storage` (nixosTest).
- Doc path references — L1 check `doc-refs`.
- Service contract conformance — L1 check `contract-conformance`.
- vmtest OIDC wiring (plugins/branding/boot-activation present in
  rendered jellarr config) — L1 check `vmtest-wiring`.
- Dex OIDC discovery + password grant with groups claim — observed
  PASS in the 2026-07-29 e2e run (bootstrap script sections
  "dex OIDC discovery" / "Dex test user").
- CryptPad `/checkup/` 200 — observed PASS in the 2026-07-29 e2e run.

## Broken / landmines

- **P0: jellarr fails on fresh boot.** 2026-07-29 e2e run:
  `cococoir-jellarr-api-key` OK → `jellarr-api-key-bootstrap` OK
  (stops jellyfin, inserts key, restarts) → `jellarr` starts 3s
  later and dies with `connect ECONNREFUSED 127.0.0.1:8096`;
  jellyfin health was 502 at the same moment. Either jellyfin was
  crash-looping (check its journal first — OIDC plugin DLLs are
  the newest variable) or the preStart readiness probe raced the
  restart. Reproduce: `bash scripts/vmtest-e2e.sh`. Until this is
  fixed, "OIDC works" is unproven on fresh boot — the exact
  regression class the e2e script exists to catch.
- `jellarr.timer` (daily) can rerun jellarr against a live system;
  harmless but unverified.

## Current focus

Jellyfin OIDC via Dex, proven on a fresh boot by
`scripts/vmtest-e2e.sh`. Nothing else ships until P0 above is green.
