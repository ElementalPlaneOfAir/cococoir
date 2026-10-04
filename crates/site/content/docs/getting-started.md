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

- **Linux native** (any distro): `system-manager` applies the fortress
  services to the host's systemd (in place). Install with
  `curl https://proletariat.tech/install.sh | bash`.
- **macOS / Windows** (Linux VM): a single Linux VM runs the stack
  (system-manager inside); the host is just hardware. Provision with
  `curl https://proletariat.tech/install.sh | bash`.
- **Full guide**: [the install script page](/docs/install-script).

> **Note (ADR-035):** the automated provisioners for these two methods
> are being rebuilt now that the Docker container tier is removed;
> `install.sh` currently reports the method but installs nothing yet.
> The demo stack (login `admin@example.com` / `password`) is unchanged.

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
