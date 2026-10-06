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

# The generator needs age-keygen, sops, git, openssl, mkpasswd and
# xkcdpass. Provisioning those per-distro would be a support matrix, and
# every target already has nix (ADR-035 assumes it), so pull the missing
# ones from there and re-exec. Only fires when something is absent — a
# host that already carries them stays dependency-free.
REQUIRED_TOOLS=(age-keygen sops git openssl mkpasswd xkcdpass)
missing=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  command -v nix >/dev/null 2>&1 || {
    echo "fortress-bootstrap: missing ${missing[*]} and no nix to supply them" >&2
    exit 1
  }
  echo "fortress-bootstrap: supplying ${missing[*]} via nix" >&2
  exec nix shell --extra-experimental-features 'nix-command flakes' \
    nixpkgs#age nixpkgs#sops nixpkgs#git nixpkgs#openssl nixpkgs#mkpasswd nixpkgs#xkcdpass \
    --command bash "$0" "$@"
fi

ROOT="/etc/fortress"
OWNER_KEYS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a path}"; shift 2 ;;
    --owner-key) OWNER_KEYS+=("${2:?--owner-key needs an age pubkey}"); shift 2 ;;
    *) echo "fortress-bootstrap: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

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
# secrets/secrets.enc.yaml carries sealed secrets. `git revert` +
# `fortress-apply` rolls config AND secrets back together. The device key
# at ../system_age_keys.txt decrypts the secrets and is never in this repo.
{
  description = "Fortress configuration";
  inputs.cococoir.url = "github:ElementalPlaneOfAir/cococoir/main";
  outputs = {cococoir, ...}: {
    # `systemConfigs.fortress` is what `fortress-apply` builds and installs
    # onto the host's systemd. Nothing here goes through nixos-rebuild:
    # updating fortress is edit + `fortress-apply`, never a system rebuild.
    systemConfigs.fortress = cococoir.lib.mkFortressSystemConfig ({...}: {
      imports = [ ./config.nix ];
      nixpkgs.hostPlatform = "x86_64-linux";
      # sops-wire does the rest: device key at
      # /etc/fortress/system_age_keys.txt, the admin env template, etc.
      fortress.secrets.sopsFile = ./secrets/secrets.enc.yaml;
    });
  };
}
FLAKE
  cat > "$CONFIG/config.nix" <<'CONFIG'
# The flat, editor-managed app config — one file. The fortress dashboard
# edits exactly these fields (services + remote-access + users); anything
# it does not touch survives a save untouched. Edit here or in the UI,
# then `fortress-apply`; `git revert` to undo. Secrets live in secrets/.
{
  ...
}: {
  # Exposure (remote-access): the platform domain your box serves under.
  # (The OS keeps the hostname — this layer never touches it.)
  fortress.baseDomain = "example.com";

  # Storage: the HOST owns btrfs (pools, quotas, scrub). Fortress just
  # writes under `dataRoot`, so point that at wherever your storage is
  # mounted. `plain-dirs` is the backend that assumes exactly this.
  fortress.storage = {
    backend = "plain-dirs";
    dataRoot = "/data";
  };

  # Which fortress services run. The dashboard toggles these. `dex` is the
  # always-on OIDC provider everything else signs in through, so it stays
  # on. Enabling a service that is not yet on the applier fails loudly
  # rather than building a unit that cannot start.
  fortress.services = {
    dex.enable = true;
    # jellyfin.enable = true;
    # cryptpad.enable = true;
    # forgejo.enable = true;
    # seerr.enable = true;
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
generated_secrets=0
if [ ! -f "$SECRETS" ]; then
  # correct-horse-battery-staple: an operator reads this off the terminal
  # and types it at the login prompt, so it has to be speakable. Five words
  # from xkcdpass's list is ~64 bits — stronger than the 24-char token it
  # replaces, and far easier to handle at first boot.
  admin_pw="$(xkcdpass -n 5 -d - -c 1)"
  case "$admin_pw" in
    *-*-*-*) ;;
    *) echo "fortress-bootstrap: passphrase malformed: $admin_pw" >&2; exit 1 ;;
  esac
  admin_hash="$(printf '%s' "$admin_pw" | mkpasswd -m bcrypt -R 10 -s)"
  jellarr_key="$(openssl rand -hex 32)"
  jellyfin_pw="$(xkcdpass -n 5 -d - -c 1)"
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
  generated_secrets=1
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
echo "  config:     $CONFIG (git repo — edit, commit, or 'git revert' + apply)"

# Shown exactly once, at the moment the operator is looking at the terminal
# and can move it into a password manager. Repeats keep the secrets sealed;
# recovering later means `sops -d $SECRETS`.
if [ "$generated_secrets" = 1 ]; then
  echo ""
  echo "  ────────────────────────────────────────────────────────────"
  echo "  ADMIN PASSWORD — shown once, save it now:"
  echo ""
  echo "      $admin_pw"
  echo ""
  echo "  Jellyfin admin password (also once):"
  echo ""
  echo "      $jellyfin_pw"
  echo "  ────────────────────────────────────────────────────────────"
  echo ""
  echo "  Recoverable later with: sops -d $SECRETS"
fi
