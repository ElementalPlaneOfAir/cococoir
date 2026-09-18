#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# install.sh — the container tier's install moment (macOS / Linux /
# NixOS). Detects the OS, (optionally) installs GUM + docker, writes
# a small deployment flake into a customer-chosen folder, builds the
# fortress-container rootfs tarball, imports it into docker, and
# boots the stack. Honest boundary: the macOS path is UNTESTED
# (nixosConfigurations/fortress-container.nix) and cross-building an
# x86_64-linux NixOS rootfs from a non-x86_64-linux host needs a
# Linux builder — the script attempts it and reports failures
# instead of pretending they can't happen.
set -euo pipefail

REPO="github:ElementalPlaneOfAir/cococoir/main"
CONTAINER=fortress-demo
IMAGE=fortress:demo
PORT=8443
SUDO=""
command -v sudo >/dev/null 2>&1 && [ "$(id -u)" != 0 ] && SUDO=sudo

# ---- TUI: GUM when present, plain prompts otherwise ----------------
GUM=""
command -v gum >/dev/null 2>&1 && GUM=gum

hdr() {
  if [ -n "$GUM" ]; then
    gum style --border rounded --border-foreground 212 --padding "0 1" -- \
      "$1"
  else
    printf '\n==> %s\n' "$1"
  fi
}
msg() {
  if [ -n "$GUM" ]; then gum style --foreground 250 "$1"; else printf '    %s\n' "$1"; fi
}
warn() {
  if [ -n "$GUM" ]; then gum style --foreground 214 --bold "$1"; else printf '    WARN: %s\n' "$1" >&2; fi
}
die() {
  if [ -n "$GUM" ]; then gum style --foreground 203 --bold "$1" || true; fi
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}
prompt_arg() { # prompt default -> stdout: value
  local question=$1 default=${2:-} answer
  if [ -n "$GUM" ]; then
    answer="$(gum input --placeholder "$question" --value "$default" </dev/tty)" || answer="$default"
  else
    printf '%s [%s]: ' "$question" "$default" >&2
    read -r answer </dev/tty || answer="$default"
  fi
  printf '%s' "${answer:-$default}"
}

# ---- OS detection ---------------------------------------------------
detect_os() {
  if [ "$(uname -s)" = "Darwin" ]; then echo macos
  elif [ -f /etc/NIXOS ] || grep -qs '^ID=nixos$' /etc/os-release 2>/dev/null; then echo nixos
  elif [ "$(uname -s)" = "Linux" ]; then echo linux
  else echo unknown
  fi
}
OS="$(detect_os)"
[ "$OS" = unknown ] && die "Neither macOS nor Linux — this installer can't proceed."

hdr "Fortress installer — detected: $OS"

# ---- Package helpers -------------------------------------------------
install_pkg() { # returns 0 on success; silent best-effort
  local pkg=$1
  if command -v brew >/dev/null 2>&1; then brew install -q "$pkg"
  elif command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$pkg"
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y -q "$pkg"
  elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -Sy --noconfirm -q "$pkg"
  else return 1
  fi
}

# ---- GUM (TUI niceties; degrades if unavailable) ---------------------
if [ -z "$GUM" ]; then
  msg "GUM not found — installing it for a nicer setup experience..."
  if ! command -v gum >/dev/null 2>&1 && install_pkg gum; then
    GUM=gum; hdr "Fortress installer — detected: $OS"
  else
    warn "GUM unavailable; continuing with plain prompts."
  fi
fi

# ---- Docker: install or confirmed no-op ------------------------------
docker_ready() { [ -n "$(command -v docker)" ] && docker info >/dev/null 2>&1; }

install_docker() {
  if docker_ready; then
    warn "Docker is already installed and running — skipping installation (no-op)."
    return 0
  fi
  case $OS in
    macos)
      command -v brew >/dev/null 2>&1 ||
        die "Docker missing and Homebrew is not installed: install Docker Desktop (https://docker.com) and re-run."
      msg "Installing Docker Desktop via Homebrew (accept its root helper prompt)..."
      brew install --cask docker
      msg "Starting Docker Desktop..."
      open -a Docker || true
      ;;
    linux)
      msg "Installing docker..."
      if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq docker.io
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y -q docker
      elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm docker
      else
        die "No supported package manager (apt-get/dnf/pacman) found — install docker manually and re-run."
      fi
      msg "Enabling + starting the docker service..."
      $SUDO systemctl enable --now docker
      ;;
    nixos)
      warn "Docker not found. On NixOS it belongs in configuration.nix, not a script:"
      msg "  # add to your configuration.nix, then nixos-rebuild switch:"
      msg "  virtualisation.docker.enable = true;"
      ;;
  esac
  if [ "$OS" != nixos ]; then
    msg "Waiting for the docker daemon..."
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
    docker_ready || die "Docker installed but the daemon is not responding — start Docker Desktop / docker service and re-run."
  fi
}
install_docker

# ---- Config folder + deployment flake (macOS / regular Linux) --------
if [ "$OS" != nixos ]; then
  CONFIG_DIR="$(prompt_arg "Where should the Fortress config folder live?" "$HOME/fortress-config")"
  mkdir -p "$CONFIG_DIR"
  flake_file="$CONFIG_DIR/flake.nix"
  if [ -e "$flake_file" ]; then
    warn "$flake_file already exists — leaving it untouched."
  else
    msg "Writing the deployment flake in $CONFIG_DIR"
    cat > "$flake_file" <<'EOF'
# Fortress container deployment. This wraps the upstream Fortress
# flake; add `modules = [...]` to extendModules below to customize.
{
  inputs.fortress.url = "github:ElementalPlaneOfAir/cococoir/main";

  outputs = { self, fortress }: {
    nixosConfigurations.fortress-container =
      fortress.nixosConfigurations.fortress-container;
  };
}
EOF
    [ -e "$CONFIG_DIR/.gitignore" ] || printf 'result\n' > "$CONFIG_DIR/.gitignore"
  fi
fi

# ---- Hosts entries (container tier uses *.vmtest.local) -------------
HOSTS_ENTRIES="127.0.0.1 jellyfin.vmtest.local auth.vmtest.local cryptpad.vmtest.local"
if ! grep -qs 'jellyfin.vmtest.local' /etc/hosts; then
  warn "Hosts entries needed so your browser finds the local services."
  $SUDO sh -c "printf '\n$HOSTS_ENTRIES\n' >> /etc/hosts" 2>/dev/null &&
    msg "Hosts entries added." ||
    die "Could not edit /etc/hosts. Run with sudo: sudo sh -c 'echo \"$HOSTS_ENTRIES\" >> /etc/hosts'"
fi

# ---- Build -------------------------------------------------------------
hdr "Building the Fortress container image (this can take many minutes)"
if [ "$OS" != nixos ]; then
  if ! command -v nix >/dev/null 2>&1; then
    die "Nix is not installed. Install it first: curl -fsSL https://nixos.org/install.sh | sh  (then re-run)."
  fi
  case $(uname -m) in x86_64) ;; *)
    warn "Build machine is $(uname -m), but the container rootfs is x86_64-linux." ;;
  esac
fi
TARBALL_REF="$REPO#nixosConfigurations.fortress-container.config.system.build.tarball"
[ "$OS" != nixos ] && TARBALL_REF=".#nixosConfigurations.fortress-container.config.system.build.tarball"
tarball="$(nix build --print-out-paths "$TARBALL_REF" --no-link | tail -1)"
[ -n "$tarball" ] || die "The rootfs tarball build produced no output path."
ROOTFS="$tarball/tarball/nixos-system-x86_64-linux.tar.xz"
[ -f "$ROOTFS" ] || die "Expected rootfs tarball $ROOTFS not found."

# ---- Deploy ------------------------------------------------------------
$SUDO docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
if sudo -n true 2>/dev/null || [ "$(id -u)" = 0 ] || [ "$OS" = macos ]; then
  RT_RUN=(docker)
else
  RT_RUN=(sudo docker)
fi

msg "Importing rootfs into docker (streamed)..."
xz -dc "$ROOTFS" | "${RT_RUN[@]}" import - "$IMAGE" >/dev/null

msg "Booting container (systemd as PID 1, privileged) on port $PORT..."
"${RT_RUN[@]}" run --privileged -d --name "$CONTAINER" -p ${PORT}:443 \
  -v fortress-data:/data "$IMAGE" /init >/dev/null

hdr "Waiting for the boot to settle (up to ~2 minutes)"
healthy=no
for _ in $(seq 1 60); do
  code="$(curl -k --max-time 5 -s -o /dev/null -w '%{http_code}' \
    --resolve jellyfin.vmtest.local:${PORT}:127.0.0.1 \
    https://jellyfin.vmtest.local:${PORT}/health || true)"
  if [ "$code" = 200 ]; then healthy=yes; break; fi
  sleep 2
done

hdr "Fortress is up"
if [ "$healthy" != yes ]; then
  warn "Jellyfin health did not return 200 yet — it may still be booting. Docker logs: docker logs $CONTAINER"
fi
msg "Login (Dex): admin@example.com / password   (self-signed cert — accept the risk)"
msg "  https://jellyfin.vmtest.local:${PORT}/   (media)"
msg "  https://auth.vmtest.local:${PORT}/        (SSO)"
msg "  https://cryptpad.vmtest.local:${PORT}/    (docs)"
msg "Manage: docker stop|start|rm $CONTAINER ; data persists in the fortress-data volume."
[ "$OS" = macos ] && warn "macOS support for this tier is untested (see nixosConfigurations/fortress-container.nix) — if anything above failed, that's the likely culprit."
[ "$OS" != nixos ] && msg "Deployment flake: $CONFIG_DIR/flake.nix — edit + re-run 'nix build && docker import' to update."
