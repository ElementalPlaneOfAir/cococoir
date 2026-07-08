# SPDX-License-Identifier: AGPL-3.0-or-later
# Cococoir v2 — tenant module.
#
# Defines the `cococoir.tenant.<name>` option tree and derives all
# readOnly per-tenant values (subdomains, bucket names).
#
# Customer-facing config (the entire surface for v0):
#
#   cococoir.tenant.alice = {
#     domain              = "alice.untitledbusiness.info";
#     adminUser           = "alice";
#     adminPasswordFile   = config.sops.secrets."alice-admin".path;
#   };
#
# Everything else (services.jellyfin.domain, services.jellyfin.bucket,
# services.cryptpad.domain, services.cryptpad.bucket, pocketid.domain)
# is derived here and declared readOnly. The customer cannot set them.
#
# v0 service list: jellyfin, cryptpad. Adding a service means:
#   1. Add it to nixos-modules/services/<name>.nix (declare its slots)
#   2. Add it to the per-tenant derivation below (subdomain + bucket)
{config, lib, ...}:
with lib; {
  options.cococoir.tenant = mkOption {
    type = types.attrsOf (types.submodule ({name, config, ...}: {
      options = {
        domain = mkOption {
          type = types.strMatching "^[a-z0-9-]+(\\.[a-z0-9-]+)+$";
          description = ''
            The customer's apex domain (e.g. alice.untitledbusiness.info).
            Must be a valid lowercase domain.
          '';
          example = "alice.untitledbusiness.info";
        };

        adminUser = mkOption {
          type = types.addCheck types.str (u: u != "");
          description = ''
            Unix and PocketID username for the customer's admin. Same
            name, same password file, used for both.
          '';
          example = "alice";
        };

        adminPasswordFile = mkOption {
          type = types.path;
          description = ''
            Path to a file containing the admin's password. The consumer wires this
            from sops-nix, age, or whatever they choose. Cococoir doesn't care.
            The file must exist at eval time (Nix's path type enforces this).
          '';
          example = "/run/secrets/alice-admin";
        };

        # ── Derived: PocketID ──────────────────────────────────────
        # Always-on base layer. One PocketID per tenant. v0 hosts the
        # OIDC provider at `auth.${domain}`. Multi-tenant PocketID
        # (shared instance) is a v1+ concern. See ADR-004, ADR-005.
        pocketid.domain = mkOption {
          type = types.str;
          readOnly = true;
          description = "Derived: where PocketID serves this tenant. Always `auth.\${domain}`.";
        };

        # ── Per-service slots ──────────────────────────────────────
        # Each known service gets two readOnly derived values: its
        # subdomain and its garage bucket name. The service module
        # (services/<name>.nix) reads these and configures the service.
        #
        # No `enable` flag per ADR-012 — every customer gets every
        # known service. Add the option only when a customer asks.
        services = mkOption {
          type = types.submodule {
            options = {
              jellyfin = {
                domain = mkOption {
                  type = types.str;
                  readOnly = true;
                  description = "Derived: `jellyfin.${domain}`.";
                };
                bucket = mkOption {
                  type = types.str;
                  readOnly = true;
                  description = "Derived: `${tenantName}-jellyfin`.";
                };
              };
              cryptpad = {
                domain = mkOption {
                  type = types.str;
                  readOnly = true;
                  description = "Derived: `cryptpad.${domain}`.";
                };
                bucket = mkOption {
                  type = types.str;
                  readOnly = true;
                  description = "Derived: `${tenantName}-cryptpad`.";
                };
              };
            };
          };
          default = {};
          description = "Per-tenant service slots. All values are cococoir-derived and readOnly.";
        };
      };

      # ── Per-tenant derivation ──────────────────────────────────
      # This is the per-tenant submodule's config. It uses the
      # per-tenant `config` (this submodule's local merged value),
      # not the global `config` — no recursion.
      config = {
        pocketid.domain = "auth.${config.domain}";

        services = {
          jellyfin = {
            domain = "jellyfin.${config.domain}";
            bucket = "${name}-jellyfin";
          };
          cryptpad = {
            domain = "cryptpad.${config.domain}";
            bucket = "${name}-cryptpad";
          };
        };
      };
    }));
    default = {};
    description = ''
      Tenants configured on this machine. The customer config is the
      3 inputs and nothing more. See PLAN.md v0 architecture.
    '';
  };

  # Assertions are enforced via `check` functions on individual options
  # above (so they work in both NixOS configs and pure `lib.evalModules`
  # tests, since `assertions` is a NixOS-only option).
}
