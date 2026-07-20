# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/baseDomain — the apex domain the customer owns.
#
# The single source of truth for "what's the FQDN base for this
# machine?" Service modules' `domain` options default to
# `<conventionalSubdomain>.<baseDomain>` when baseDomain is set,
# which is the only way to keep a customer config under ~50 lines
# (see PLAN.md v2 single-machine goals; ADR-012 for the per-tenant
# vs per-machine question).
#
#   cococoir.baseDomain = "alice.example.com";
#
# Then `cococoir.services.jellyfin.domain` defaults to
# `jellyfin.alice.example.com`, `cococoir.services.pocketid.domain`
# to `auth.alice.example.com`, etc. Override any individual
# `domain` if a service needs a non-conventional name.
#
# Why null-by-default: the dev VM uses `*.vmtest.local` and sets
# `domain` per service explicitly. Production uses baseDomain. The
# factory's domain default throws if baseDomain is null and a
# service is enabled without an explicit domain — that is the
# desired failure mode (fail loud, not silently derive a
# non-resolvable name).
{lib, ...}:

{
  options.cococoir.baseDomain = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "alice.example.com";
    description = ''
      The apex domain this machine's services derive subdomains
      from. When set, each enabled service's `domain` option
      defaults to `<conventionalSubdomain>.<this value>`. When
      null, every service must set `domain` explicitly. Set this
      in the customer's `config.nix` to make the config small.
    '';
  };
}
