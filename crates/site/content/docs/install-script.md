# The install script (Linux / macOS / Windows)

One command detects the host and reports the right install method
(per ADR-035 — no Docker):

```bash
curl https://proletariat.tech/install.sh | bash
```

## Install methods (ADR-035)

- **Linux (any distro):** native install — `system-manager` applies the
  fortress services to the host's systemd (in place). OS/kernel updates
  are a separate, independent concern.
- **macOS / Windows:** a single Linux VM runs the stack (system-manager
  inside); the host is just hardware.

## Current status

The automated provisioners for the two methods are being rebuilt now
that the Docker container tier is removed (ADR-035 supersedes ADR-030).
Until they land, `install.sh` detects the host, names the method, and
reports where the pieces live — it installs nothing yet. See
`PLAN.md` ADR-035 for the model.

## The config magic folder

Fortress config lives in `/etc/fortress/config` — a git-versioned magic
folder (`config.nix` + sealed secrets + `flake.lock`). The dashboard
edits `config.nix`; applying re-reads it and re-decrypts the secrets;
`git revert` rolls config AND secrets back together. See
`PLAN.md` ADR-035.
