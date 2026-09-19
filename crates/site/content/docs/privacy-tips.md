# Privacy tips

Fortress exists so that your digital life does not need a third
party to function. These tips extend that posture to the rest of
your network and habits.

## Reduce what you carry on your main machine

- Keep your synced files inside your Fortress (CryptPad drives)
  instead of your email attachments or consumer sync apps — the
  `fortress-data` volume is the only state you need to protect.
- Backups: Fortress ships (planned v2) restic **encrypted
  offsite** backups — keys never leave the box. Until then,
  `restic` or `borg` against your own volume is the pattern.

## Harden what you self-host

- **One origin, one job.** The Caddy vhosts are public or
  private by the `public` flag of each service — keep admin
  surfaces (radarr, sonarr) non-public so they stay LAN/tunnel
  only.
- **SSO through Dex.** Enable Dex and point other apps at it —
  one identity, one password reset surface, session expiry you
  control.
- **WireGuard instead of opening ports.** Remote access goes
  through the IPv6 tunnel: nothing except Caddy's ports and the
  tunnel is exposed.

## Browser and account hygiene

- Use a password manager and a hardware second factor wherever a
  service supports it (`sudo`/`su` boxes rarely support it
  because they don't phone home).
- Email: your Fortress container tier runs no mail service — the
  SMTP seams (`MAIL_FROM`, submission relay) belong to the
  operator tier, so a lost email provider never means losing your
  self-hosted data.

## What Fortress does NOT do

- No telemetry. The box ships observability **in-process** for the
  daemon, and nothing is invented at runtime — all web assets are
  vendored and work offline.
- No external origins at runtime: the pages you load from the
  site and the box reference only hardware-you-own services.
- Your media flow (`*arr` radar family) calls third-party APIs
  for *releases* and *metadata* by design — that traffic is the
  product working, not surveillance.
