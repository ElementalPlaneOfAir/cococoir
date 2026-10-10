# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress/gate-policy — the single definition of gate group semantics.
#
# `admins` is an implicit member of every gate group, like root in unix: a
# superuser is never denied a surface just because they were not listed in
# its group. The rule is asserted here rather than repeated at each use
# because a second copy that forgets `admins` does not fail loudly — it
# silently locks the box owner out of their own media stack.
#
# Used by planes.nix (builds `?allowed_groups=` per route) and by
# integrations/dex-gate.nix (the boot-time lockout check). Both must agree,
# so there is exactly one implementation.
{lib}: {
  # gateGroups :: [string] -> [string]
  gateGroups = groups: lib.unique (groups ++ ["admins"]);
}
