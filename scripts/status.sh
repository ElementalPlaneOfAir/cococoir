#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regenerates the AUTO-STATUS block in docs/STATUS.md from real check
# results. Computed, not narrated: the block is proof, refreshed on
# every run. Never hand-edit between the markers.
#
# Exits non-zero if any check fails, so it can gate sessions and skills.
set -uo pipefail
cd "$(dirname "$0")/.."

status_file="docs/STATUS.md"
begin_marker='AUTO-STATUS:BEGIN'
end_marker='AUTO-STATUS:END'
checks=(doc-refs contract-conformance vmtest-wiring)

grep -q "$begin_marker" "$status_file" || { echo "status.sh: $begin_marker missing from $status_file" >&2; exit 1; }
grep -q "$end_marker" "$status_file" || { echo "status.sh: $end_marker missing from $status_file" >&2; exit 1; }

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sha=$(git rev-parse --short HEAD)
failed=0
lines=""
for check in "${checks[@]}"; do
  if nix build --no-link ".#checks.x86_64-linux.$check" >/dev/null 2>&1; then
    lines+="- \`$check\` — PASS"$'\n'
  else
    lines+="- \`$check\` — FAIL"$'\n'
    failed=1
  fi
done

# ── provisioning secrets resolve (the store-wiring tripwire) ─────
# The incident class: required secrets missing from the sops store or
# under the wrong project tree make provisioning fail LATE (on the
# operator's next provision run) instead of loudly here. Last incident
# truncated the store's API surface silently (2026-09-11: REDIS_URL in
# the stale cococoir-edge tree). Assert every required value in the
# provision scope resolves — without printing any value.
missing_secrets=""
for name in HETZNER_TOKEN ADMIN_KEY WG_PRIVATE_KEY REDIS_URL; do
  eval "$(nix run .#secretspec -- export -P provisioning -S provision \
    -f secretspec.toml --format shell --reason "status.sh: provision-scope tripwire" 2>/dev/null)" >/dev/null 2>&1
  [ -n "${!name:-}" ] || missing_secrets="$missing_secrets $name"
done
if [ -n "$missing_secrets" ]; then
  echo "status.sh: provisioning store missing:$missing_secrets (store: secrets/secrets.enc.yaml)" >&2
  failed=1
  lines+="- \`provisioning-store\` — FAIL:$missing_secrets"$'\n'
else
  lines+="- \`provisioning-store\` — PASS"$'\n'
fi

# ── secrets hygiene (the never-commit-plaintext tripwire) ────────
# The incident class: an operator decrypts or hand-writes a plaintext
# secret file and `git add`s it (tfvars habit, or `git add secrets/`).
# Assert the tracked file list never contains a terraform.tfvars or a
# non-encrypted file under secrets/.
# facts.json is the sanctioned exception: every value in it is
# public-by-design (tofu vars that replaced terraform.tfvars) — it is
# allowlisted here explicitly, so any OTHER plaintext file under
# secrets/ still trips this.
leaked=$(git ls-files -- secrets remote-infra/tofu \
  | grep -Ev 'secrets/.*\.enc\.|^secrets/facts\.json$' \
  | grep -E '(^|/)terraform\.tfvars|^secrets/' || true)
if [ -n "$leaked" ]; then
  echo "status.sh: PLAINTEXT SECRETS/CONFIG TRACKED IN GIT:" >&2
  echo "$leaked" | sed 's/^/  LEAKED: /' >&2
  failed=1
  lines+="- \`secrets-hygiene\` — FAIL (tracked: $leaked)"$'\n'
else
  lines+="- \`secrets-hygiene\` — PASS"$'\n'
fi

# ── crane source filter covers every include_str! target ──────────
# The incident class: a compile-time include_str! targeting an
# extension crane's filterCargoSources does not keep (.rs/.toml/
# Cargo.lock/.cargo/config only) builds fine locally but fails in the
# nix sandbox LATE (next deploy). 2026-09-18: the zine session vendored
# JS assets into crates/web-ui and nothing re-ran the nix build, so
# the remote edge deploy broke on include_str!. For each include
# target resolved against its containing .rs file, assert it is
# tracked and — when not auto-kept — explicitly re-added by the
# layered filter in nix/packages/fortress/default.nix (basename or
# extension mention).
filter_file="nix/packages/fortress/default.nix"
filter_misses=""
while IFS= read -r target; do
  base="${target##*/}"
  ext="${target##*.}"
  case "$ext" in rs|toml|lock) covered=yes ;; *) covered=no ;; esac
  if [ "$covered" = no ]; then
    if ! grep -qF "$base" "$filter_file" && ! grep -qF ".$ext" "$filter_file"; then
      filter_misses="$filter_misses $target"
    fi
  fi
  git ls-files --error-unmatch -- "$target" >/dev/null 2>&1 || {
    filter_misses="$filter_misses $target(untracked)"
  }
done < <(
  grep -rhoE 'include_(str|bytes)! *\("[^"]*"\)' crates --include='*.rs' 2>/dev/null \
    | sed -E 's/.*\("([^"]*)"\).*/\1/' | sort -u \
    | while IFS= read -r target; do
        holder="$(grep -rlF "$target" --include='*.rs' crates 2>/dev/null | head -1)"
        [ -n "$holder" ] || continue
        resolved="$(cd "$(dirname "$holder")" && realpath -m "$target" 2>/dev/null)" || continue
        rel="${resolved#$PWD/}"
        case "$rel" in "/"*|"") ;; *) [ -f "$rel" ] && printf '%s\n' "$rel" ;; esac
      done | sort -u
)

if [ -n "$filter_misses" ]; then
  echo "status.sh: INCLUDE TARGETS NOT COVERED BY nix/packages/fortress/default.nix FILTER:$filter_misses" >&2
  echo "status.sh: (locally cargo-testable, but the sandbox build will fail on next deploy)" >&2
  failed=1
  lines+="- \`src-filter-covers-includes\` — FAIL:$filter_misses"$'\n'
else
  lines+="- \`src-filter-covers-includes\` — PASS"$'\n'
fi

block="<!-- $begin_marker (regenerated by scripts/status.sh — do not hand-edit) -->"$'\n'"Regenerated: $timestamp — git $sha"$'\n'"$lines""<!-- $end_marker -->"

awk -v block="$block" '
  $0 ~ /AUTO-STATUS:BEGIN/ { print block; skip = 1; next }
  skip && $0 ~ /AUTO-STATUS:END/ { skip = 0; next }
  !skip { print }
' "$status_file" > "$status_file.tmp" && mv "$status_file.tmp" "$status_file"

if [ "$failed" -ne 0 ]; then
  echo "status.sh: FAIL — see $status_file AUTO-STATUS block" >&2
  exit 1
fi
echo "status.sh: all ${#checks[@]} checks PASS"
