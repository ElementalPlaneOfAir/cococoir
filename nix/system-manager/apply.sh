#!/usr/bin/env bash
# fortress-apply — the ADR-035 applier.
#
# Builds the fortress system-manager closure from a *runtime* flake ref (the
# magic folder) and installs its systemd units into /run/systemd/system, then
# starts fortress's own target. It deliberately does NOT run system-manager's
# activator: that manages /etc files, users, and mounts /run/wrappers — all of
# which the host OS (NixOS or Debian) already owns. Running it on NixOS fights
# the OS (read-only /etc, a tmpfs over NixOS's setuid-wrappers dir, userborn
# rewriting /etc/passwd). Fortress only needs to add service units on top of
# the OS's systemd — that is all this does.
#
# Because the closure is built and applied at run time from the flake on disk,
# updating fortress never requires `nixos-rebuild switch`: the OS closure is
# untouched; only /run/systemd/system changes.
#
# Units are grouped under `fortress.target` (declared by the fortress module),
# so starting that one target brings up exactly fortress's services — never
# system-manager's infrastructure units.
set -euo pipefail

flake="${1:-/etc/fortress/config}"
attr="${2:-systemConfigs.fortress.unitsDir}"
systemd_dir="/run/systemd/system"

# `unitsDir` is the rendered systemd unit tree — building it alone avoids
# system-manager's own activator and Rust binaries, which this applier does
# not run.
# Root the build under a persistent gcroots link. `--no-link` would leave
# the unit tree unrooted, so a `nix-collect-garbage` between apply and the
# next boot would delete it and the box would need the network (and a
# working flake.lock) to come back up. The gcroots dir survives GC and
# reboot, so an offline reboot re-installs the same store path.
gcroots="/nix/var/nix/gcroots"
install -d -m 0755 "${gcroots}"
nix build \
  --extra-experimental-features 'nix-command flakes' \
  --out-link "${gcroots}/fortress-apply" "${flake}#${attr}"
units="$(readlink -f "${gcroots}/fortress-apply")"
case "${units}" in
  /nix/store/*) ;;
  *) echo "fortress-apply: build did not yield a store path (${units})" >&2; exit 1 ;;
esac

units_dir="$(readlink -f "${units}/systemd/system")"
if [ ! -d "${units_dir}" ]; then
  echo "fortress-apply: no systemd units in ${units} (${units_dir} missing)" >&2
  exit 1
fi

# fortress-dns forwards unknown names through the host's own resolver, so the
# host must never resolve through fortress-dns — that is a loop. The module
# asserts this against `networking.nameservers`, which this layer cannot see;
# re-check the live resolver instead of trusting a vacuous assertion.
lan_address="$(
  nix eval --extra-experimental-features 'nix-command flakes' --raw \
    "${flake}#systemConfigs.fortress.config.fortress.network.lanAddress" 2>/dev/null || true
)"
if [ -n "${lan_address}" ] && [ -r /etc/resolv.conf ]; then
  while read -r kind value _; do
    if [ "${kind}" = "nameserver" ] && [ "${value}" = "${lan_address}" ]; then
      echo "fortress-apply: WARNING /etc/resolv.conf resolves through ${lan_address}," >&2
      echo "fortress-apply: WARNING which is fortress-dns itself — a resolver loop." >&2
      echo "fortress-apply: WARNING every non-service name will hang on this box." >&2
    fi
  done </etc/resolv.conf
fi

install -d -m 0755 "${systemd_dir}"
# Mirror the freshly rendered unit tree (unit files plus the .wants/.requires
# enablement) into systemd's runtime unit directory. NixOS clears /run each
# boot, so the boot trampoline re-runs this; on Debian the same path works
# unchanged.
#
# Prune what a PREVIOUS apply installed and this one no longer renders. A
# dropped unit file is merely inactive — but a leftover DROP-IN is still
# applied to the unit it names, so a stale `caddy.service.d/overrides.conf`
# silently rewrote caddy's ExecStart back to an old Caddyfile and every
# route 502'd while the unit file on disk looked correct. The manifest makes
# the applier own exactly its own surface and nothing else.
manifest=/run/fortress/installed-units
install -d -m 0755 /run/fortress
: >"${manifest}.new"
(cd "${units_dir}" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | sort) >"${manifest}.new"
if [ -f "${manifest}" ]; then
  while read -r name; do
    [ -n "${name}" ] || continue
    grep -qxF "${name}" "${manifest}.new" && continue
    echo "fortress-apply: pruning stale ${name}"
    rm -rf "${systemd_dir:?}/${name}"
  done <"${manifest}"
fi
mv "${manifest}.new" "${manifest}"

cp -a --no-dereference --remove-destination "${units_dir}/." "${systemd_dir}/"

systemctl daemon-reload

# Bring up exactly fortress's services. `fortress.target` lists them in its
# own `Wants=` (it is deliberately separate from `system-manager.target`,
# whose infra units would fight the host OS). Restart each so a changed
# config (new ExecStart/config file) takes effect; system-manager diffs unit
# store paths to restart only what moved, but fortress boxes are
# single-tenant and restarting the set is simpler and always correct.
target_unit="${systemd_dir}/fortress.target"
if [ -f "${target_unit}" ]; then
  systemctl start fortress.target
  wants=""
  while IFS= read -r line; do
    case "${line}" in
      Wants=*) wants="${wants} ${line#Wants=}" ;;
    esac
  done <"${target_unit}"
  for unit in ${wants}; do
    systemctl restart "${unit}"
  done
fi

echo "fortress-apply: applied ${units} (${flake}#${attr})"
