# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — top-level placeholder module.
#
# v0 architecture (see PLAN.md): the entire tenant surface is a freeform
# attrset under `cococoir.tenant.<name>`. Each tenant is currently
# `{ domain, adminUser, adminPasswordFile }`. Day 3-4 will turn this into
# a typed option tree with derived subdomains, services, OIDC clients, etc.
{lib, ...}: {
  options.cococoir.tenant = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = {};
    example = lib.literalExpression ''
      {
        alice = {
          domain = "alice.example.com";
          adminUser = "alice";
          adminPasswordFile = "/run/secrets/alice-admin";
        };
      }
    '';
    description = ''
      Tenants configured on this machine. Each tenant is a name → attrset.
      The full schema is defined in PLAN.md (3 inputs: domain, adminUser,
      adminPasswordFile). All subdomains, services, OIDC clients, and
      storage are derived from these three inputs.

      v0 (Day 1-2): freeform attrset, no logic.
      v0 Day 3-4: typed submodule with the 3 options.
    '';
  };
}
