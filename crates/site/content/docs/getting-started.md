# Get started with Fortress

Fortress is your home server: media, documents, passwords and
photos on hardware you own, with remote access that does not
depend on anyone's cloud account.

## If you have a Fortress box

1. Plug the box into power and ethernet. Wait for it to boot —
   under five minutes on first start.
2. Claim it: sign in at [proletariat.tech](/), open **Your machines**
   and generate an invite link. On the box, open its dashboard and
   paste the link into **Remote access**. Approve and name the machine
   back on **Your machines**.
3. Sign in at your domain (`https://<machine>.<your-domain>`).

## If you installed on your own hardware

- **Container tier** (macOS or regular Linux, demo stack): set up
  with `curl https://proletariat.tech/install.sh | bash`, then
  visit `https://jellyfin.vmtest.local:8443`. The script adds the
  `*.vmtest.local` hosts entries. Demo login is
  `admin@example.com` / `password` — the same demo stack as the
  boxes ship with, before your account is attached.
- **NixOS module** (native path): see [the NixOS guide](/docs/nixos).
- **Container tier on NixOS?** The script does not manage a NixOS
  box — add `virtualisation.docker.enable = true` and use the
  same one-liner.
- **Full guide**: [the install script page](/docs/install-script).

## What you get

- **Jellyfin** — your Netflix: movies, series and music from your
  own library, reachable anywhere through the tunnel.
- **CryptPad** — your Google Docs: encrypted collaborative
  documents, spreadsheets and forms.
- **Media automation** — radarr, sonarr, qBittorrent and overseerr
  bring your library up to date; Jellyfin front-ends it.

## The dashboard

The dashboard is the control surface of your Fortress machine:
machines, invites, remote access and service settings. The
customer-configurable surface is deliberately small — storage,
TLS and DNS follow your domain automatically.

## Verify it works

- `https://<machine>.<your-domain>/login` — the SSO login page
  (Dex) should render and accept your account.
- Media: point Jellyfin at a library, play something from the
  living room and from a phone.
- Remote: from outside your home network, open the same Jellyfin
  URL — it should load through the tunnel.
