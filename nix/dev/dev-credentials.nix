# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The dev/test tier's admin credential, defined exactly once.
#
# This bcrypt used to be copy-pasted across flake.nix, demo-base.nix
# (twice), smtest.nix and tests/edge — and one copy sat next to a dead
# `ADMIN_HASH` variable while the minting path emitted `openssl rand
# -hex 32`, so the dashboard login could never succeed. Every Nix
# consumer reads this file instead.
#
# The two Rust unit tests (crates/client/src/dashboard/{auth,mod}.rs)
# keep their own literal on purpose: a unit test must not depend on
# Nix evaluation. If you change this, change those too.
{
  password = "password";

  # bcrypt, cost 10, of `password`. A hash cannot be regenerated from
  # the plaintext (salts are random), so there is no build-time check
  # that these two agree — the tripwire is the L2 login in
  # scripts/vmtest-bootstrap.sh, which posts `password=password`.
  adminPasswordHash = "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W";
}
