# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fortress v2 — full-OS container ("fortress-container").
#
# The entire demo NixOS system (systemd as PID 1, all fortress
# services, Caddy, the customer dashboard config) in one rootfs
# tarball that `docker import` accepts. This is the collaborator /
# tinkerer tier: the same demo stack as vmtest, but `docker run`
# instead of QEMU. Build + run:
#
#   nix run .#fortress-container
#
# The image boots systemd inside Docker, so the demo container runs
# --privileged (systemd needs cgroup/sysadmin caps). It runs on the
# collaborator's own machine with build-time-generated demo secrets
# only — the same trust shape as the QEMU vmtest, minus the VM.
#
# Storage: `backend = "plain-dirs"` — no btrfs inside a container;
# the same auto-declared subvolume tree is applied as plain
# directories under /data (storage/plain-dirs.nix). Persistence:
# bind-mount a host volume at /data (the run script does).
#
# macOS status: NOT yet tested. The container needs no WireGuard
# kernel module or tun device (no tunnel in the demo tier), so the
# expected risks are Docker Desktop quirks (cgroups, privileged
# mode, `docker import` of the xz tarball). If it fails there, the
# fallback is the QEMU vmtest (or Lima). Do not promise macOS
# support until `nix run .#fortress-container` has been run on a
# Mac and the asserts pass.
#
# Runtime UX (same as vmtest): add to the HOST's /etc/hosts
#   127.0.0.1 jellyfin.vmtest.local auth.vmtest.local cryptpad.vmtest.local
# then visit https://jellyfin.vmtest.local (self-signed cert —
# accept the risk), log in with admin@example.com / "password"
# (Dex static password from demo-base.nix).
{
  lib,
  inputs,
  ...
}: {
  imports = [./demo-base.nix];

  # Container tier storage (ADR-023 remains the customer tier):
  # no btrfs; plain directories under /data, converged on boot by
  # tmpfiles with the same owner/mode semantics.
  fortress.storage.backend = "plain-dirs";
  fortress.storage.dataRoot = "/data";

  # Docker's userland proxy connects into the container's eth0 IP,
  # not loopback — Caddy must bind the wildcard (0.0.0.0). The
  # `_contract.nix` "never 0.0.0.0" rule protects the client
  # forwarder's tunnel-IP ingress; this tier has no client
  # forwarder (the tunnel story is v2/v3, not the container demo),
  # so the rule's reason does not apply here. The
  # `container-wiring` L1 check asserts this bind survives
  # composition. The ADR-028 LAN plane (dnsmasq) is dead by design
  # in a container — lanAddress stays null and access is via
  # published ports + the host's /etc/hosts.
  fortress.network.caddyBindAddresses = ["127.0.0.1" "0.0.0.0"];

  # No firewall inside the container (the docker-image module
  # disables it — iptables don't work in Docker); published ports
  # are the boundary.
  #
  # dashboard.nix (the customer file) names the box "vmtest"; the
  # container tier forces its own identity.
  networking.hostName = lib.mkForce "fortress-container";

  # systemd's TasksMax default is derived from the container's
  # cgroup/user-namespace context and lands at ~300 inside rootless
  # podman — cryptpad's node worker spawn hits EAGAIN and the unit
  # start-limit-loops (found in the first container boot,
  # 2026-09-15). 4096 bounds it well above what the stack needs
  # (the vmtest tier's computed default is thousands) while keeping
  # a fork-bomb bound.
  systemd.settings.Manager.DefaultTasksMax = 4096;

  # Kernel debug/trace mounts always fail inside a container (no
  # debugfs/tracing from the host kernel); suppress them so
  # `systemctl --failed` is a clean signal in the e2e gate.
  systemd.suppressedSystemUnits = [
    "sys-kernel-debug.mount"
    "sys-kernel-tracing.mount"
  ];

  # Keep the container lean: the demo tier's closure is the
  # product, not a dev workstation. No SSH, no editor, no VM tools.
}
