#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress-bootstrap — generate the Fortress magic folder on first run.
#
# One shared generator behind every install target (Linux native oneshot,
# the Mac-Windows VM, the install script). Idempotent: never clobbers an
# existing folder. The folder it produces is the single editable surface the
# customer and the WebUI touch, and the git repo rolls config AND sealed
# secrets back together with `git revert` + rebuild.
#
# Layout (the constant across every target):
#   $ROOT/system_age_keys.txt  device age key — OUTSIDE the repo, never
#                                committed; decrypts the sealed secrets.
#   $ROOT/config/                a git repo
#     config.nix                 the flat editor-managed app config (services +
#                                remote-access + users) — one file
#     flake.nix                  composes config.nix + secrets + fortress modules
#     flake.lock                 pins fortress — rolled back with the config
#     secrets/secrets.enc.yaml   sops-encrypted secrets (ciphertext committed)
set -euo pipefail

ROOT="/etc/fortress"
OWNER_KEYS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a path}"; shift 2 ;;
    --owner-key) OWNER_KEYS+=("${2:?--owner-key needs an age pubkey}"); shift 2 ;;
    *) echo "fortress-bootstrap: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "fortress-bootstrap: required tool missing: $1" >&2; exit 1
  }
}
for tool in age-keygen sops git openssl mkpasswd; do need "$tool"; done

CONFIG="$ROOT/config"
KEYFILE="$ROOT/system_age_keys.txt"
SECRETS="$CONFIG/secrets/secrets.enc.yaml"

mkdir -p "$CONFIG/secrets"
[ -d "$CONFIG/secrets" ] || { echo "fortress-bootstrap: cannot create $CONFIG/secrets" >&2; exit 1; }

# ── 1. device age key (idempotent) ───────────────────────────────────
if [ ! -f "$KEYFILE" ]; then
  umask 077
  age-keygen -o "$KEYFILE" >/dev/null 2>&1
  chmod 600 "$KEYFILE"
fi
[ -f "$KEYFILE" ] || { echo "fortress-bootstrap: device key missing at $KEYFILE" >&2; exit 1; }
DEVICE_PUB="$(age-keygen -y "$KEYFILE")"
case "$DEVICE_PUB" in
  age1*) ;;
  *) echo "fortress-bootstrap: device pubkey malformed: $DEVICE_PUB" >&2; exit 1 ;;
esac

# ── 2. git repo (idempotent) ─────────────────────────────────────────
if [ ! -d "$CONFIG/.git" ]; then
  git -C "$CONFIG" init -q
fi
[ -d "$CONFIG/.git" ] || { echo "fortress-bootstrap: git init failed in $CONFIG" >&2; exit 1; }

# ── 3. config skeleton (idempotent — only when missing) ─────────────
if [ ! -f "$CONFIG/flake.nix" ]; then
  cat > "$CONFIG/flake.nix" <<'FLAKE'
# Fortress configuration — the single editable surface. `config.nix` is
# the flat, editor-managed app config (services + remote-access + users);
# secrets/secrets.enc.yaml carries sealed secrets. `git revert` + rebuild
# rolls config AND secrets back together. The device key at
# ../system_age_keys.txt decrypts the secrets and is never in this repo.
{
  description = "Fortress configuration";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    fortress.url = "github:ElementalPlaneOfAir/cococoir/main";
  };
  outputs = {
    self,
    nixpkgs,
    fortress,
    ...
  }: {
    nixosConfigurations.fortress = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        fortress.nixosModules.default
        ./config.nix
        {
          # sops-wire (inside fortress.nixosModules.default) does the rest:
          # device key at /etc/fortress/system_age_keys.txt, admin env, etc.
          fortress.secrets.sopsFile = ./secrets/secrets.enc.yaml;
          system.stateVersion = "25.05";
        }
      ];
    };
  };
}
FLAKE
  cat > "$CONFIG/config.nix" <<'CONFIG'
# The flat, editor-managed app config — one file. The fortress dashboard
# edits exactly these fields (services + remote-access + users); anything
# it does not touch survives a save untouched. Edit here or in the UI,
# then rebuild; `git revert` to undo. Secrets live in secrets/.
{
  ...
}: {
  # Exposure (remote-access): the box's name and the platform domain.
  networking.hostName = "fortress";
  fortress.baseDomain = "example.com";

  # Which fortress services run. The dashboard toggles these.
  fortress.services = {
    jellyfin.enable = true;
    jellarr.enable = true;
    dex.enable = true;
    cryptpad.enable = true;
    forgejo.enable = true;
    seerr.enable = true;
  };

  # Box login users (optional). The dashboard edits groups / password hashes.
  # users.users = { };
}
CONFIG
fi
[ -f "$CONFIG/flake.nix" ] || { echo "fortress-bootstrap: flake.nix missing after write" >&2; exit 1; }
[ -f "$CONFIG/config.nix" ] || { echo "fortress-bootstrap: config.nix missing after write" >&2; exit 1; }

# ── 3b. flake.lock (best-effort — pins fortress for reproducible rollback) ─
if [ ! -f "$CONFIG/flake.lock" ] && command -v nix >/dev/null 2>&1; then
  nix flake lock "$CONFIG" >/dev/null 2>&1 ||
    echo "fortress-bootstrap: flake.lock not created (offline / inputs unfetchable) — a later rebuild adds it." >&2
fi

# ── 4. sealed secrets (idempotent — only when missing) ───────────────
if [ ! -f "$SECRETS" ]; then
  admin_pw="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  admin_hash="$(printf '%s' "$admin_pw" | mkpasswd -m bcrypt -R 10 -s)"
  jellarr_key="$(openssl rand -hex 32)"
  jellyfin_pw="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  case "$admin_hash" in
    \$*) ;;
    *) echo "fortress-bootstrap: bcrypt hash malformed: $admin_hash" >&2; exit 1 ;;
  esac

  RECIPIENTS="$DEVICE_PUB"
  for owner in ${OWNER_KEYS[@]+"${OWNER_KEYS[@]}"}; do
    RECIPIENTS="$RECIPIENTS,$owner"
  done

  plaintext="$(mktemp)"
  trap 'rm -f "$plaintext"' EXIT
  # printf, not a heredoc: bcrypt hashes carry `$`, which an unquoted
  # heredoc would expand as shell variables and corrupt the hash.
  {
    printf 'fortress-admin-password: "%s"\n' "$admin_pw"
    printf 'fortress-admin-password-hash: "%s"\n' "$admin_hash"
    printf 'jellarr-api-key: "%s"\n' "$jellarr_key"
    printf 'jellyfin-admin-password: "%s"\n' "$jellyfin_pw"
  } > "$plaintext"

  sops --encrypt --age "$RECIPIENTS" --input-type yaml --output-type yaml \
    "$plaintext" > "$SECRETS"
  rm -f "$plaintext"
  trap - EXIT
fi
[ -f "$SECRETS" ] || { echo "fortress-bootstrap: sealed secrets missing at $SECRETS" >&2; exit 1; }
grep -q 'ENC\[' "$SECRETS" || { echo "fortress-bootstrap: $SECRETS is not sops-encrypted" >&2; exit 1; }
grep -q 'fortress-admin-password-hash' "$SECRETS" || { echo "fortress-bootstrap: admin hash key absent from $SECRETS" >&2; exit 1; }

# ── 5. commit (idempotent — only when there are staged changes) ──────
git -C "$CONFIG" add -A
if ! git -C "$CONFIG" diff --cached --quiet; then
  git -C "$CONFIG" -c user.email="fortress@localhost" -c user.name="fortress" \
    commit -qm "fortress: bootstrap config + sealed secrets"
fi

echo "fortress magic folder ready at $ROOT"
echo "  device key: $KEYFILE (outside the repo — back this up)"
echo "  config:     $CONFIG (git repo — edit, commit, or 'git revert' + rebuild)"
