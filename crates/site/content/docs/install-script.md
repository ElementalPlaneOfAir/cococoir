# The install script (macOS / Linux)

One command sets up the demo container tier on a Mac or a
regular Linux box:

```bash
curl https://proletariat.tech/install.sh | bash
```

## What it does, step by step

1. **Detects the OS** — macOS, regular Linux, NixOS.
2. **Installs gum** (optional TUI; falls back to plain prompts if
   it cannot be installed) and **docker** — a no-op with a
   warning if docker is already installed and running.
3. **Asks for a config folder** (default `~/fortress-config`)
   and writes a small deployment flake into it. That flake pins
   the upstream Fortress flake, which is what the demo image is
   built from.
4. **Builds the image** — a full NixOS rootfs (systemd as PID 1,
   services included) built by nix. This is the download-and-
   compile step; it can take many minutes.
5. **Boots the stack** — `docker run --privileged` with
   `systemd` as PID 1, publishes the HTTPS port at `:8443`, and
   persistence lives in the `fortress-data` docker volume.

## NixOS

The script **stops** on a NixOS box without docker and points at
[the NixOS guide](/docs/nixos). Add
`virtualisation.docker.enable = true;` to `configuration.nix` if
you want the container tier on it.

## Landmines worth knowing

- **The privileged container runs systemd inside Docker.** That
  is the same trust shape as a QEMU demo VM — this tier is a
  demonstration, not a security boundary.
- **macOS is untested.** `nixosConfigurations/fortress-container.nix`
  lists the expected risks (Docker Desktop cgroups, `import`
  behavior). If the run fails on a Mac, that's the first place to
  look; the fallback is the QEMU VM.
- **Cross-building**: the image is `x86_64-linux`. On an Apple
  Silicon Mac a cross build needs a Linux builder — the script
  attempts the build and reports the failure instead of
  pretending it can't happen.
- **App state under `/var/lib` inside the container** resets on
  recreate; only the `/data` volume persists.

## Updating after install

Edit `$HOME/fortress-config/flake.nix` (e.g. change service
settings by adding extendModules), then re-run the build + import
steps in the folder.
