# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress sops-wire — the single place secret *material* is declared.
#
# `fortress.secrets.sopsFile` (secrets.nix) is the one-line switch: it is
# the sealed inventory, and everything below derives from it. Services
# never declare their own secret plumbing and never mint a value at boot —
# they read `config.sops.secrets.<key>.path` or `config.sops.templates.<n>.path`.
#
# Why the values are sealed rather than generated: ciphertext in the store
# is safe *and* deterministic, so a rebuild reproduces the box exactly and
# the only thing that lives outside the store is the device age key.
# Minting at boot (`openssl rand`, the pre-2026-10-08 shape) traded one
# problem for another — no store leak, but every rebuild rotated every key
# and silently broke the integrations that had registered the old one.
#
# On-box layout (see .specify/specs/onbox-config-secrets/proposal.md):
#   /etc/fortress/system_age_keys.txt — device age private key (never in
#     git, never a store path). Secrets are sealed to this key plus an
#     owner key, so the config's git source holds only ciphertext, and the
#     box can rotate secrets without the owner's master key.
#
# This is a SIBLING of secrets.nix (which declares `fortress.secrets.*`).
# It only READS those options to contribute to FOREIGN option trees
# (sops.secrets / sops.templates / services.*) — the shape that avoids the
# module-system recursion described in AGENTS.md.
{lib, config, ...}:
let
  inventory = config.fortress.secrets._inventory;
  deviceKeyFile = "/etc/fortress/system_age_keys.txt";

  # Env-file templates: one per service whose systemd unit wants the
  # secret as KEY=value rather than as a bare file.
  envTemplate = content: {
    owner = "root";
    group = "root";
    mode = "0400";
    inherit content;
  };
in {
  config = {
    sops.defaultSopsFile = config.fortress.secrets.sopsFile;
    sops.age.keyFile = lib.mkDefault deviceKeyFile;

    # Every inventory key materializes at /run/secrets/<name>, owned and
    # masked per its inventory entry.
    # mkDefault: an integration that hands the secret to a non-root
    # service (jellarr, forgejo) overrides group/mode without a fight.
    sops.secrets = lib.mapAttrs (_name: spec: {
      owner = lib.mkDefault spec.owner;
      group = lib.mkDefault spec.group;
      mode = lib.mkDefault spec.mode;
    }) inventory;

    sops.templates = {
      "fortress-admin.env" = envTemplate ''
        FORTRESS_ADMIN_PASSWORD_HASH=${config.sops.placeholder.fortress-admin-password-hash}
      '';
      "jellarr.env" = envTemplate ''
        JELLARR_API_KEY=${config.sops.placeholder.jellarr-api-key}
      '';
      "radarr.env" = envTemplate ''
        RADARR__SERVER__APIKEY=${config.sops.placeholder.radarr-api-key}
      '';
      "sonarr.env" = envTemplate ''
        SONARR__SERVER__APIKEY=${config.sops.placeholder.sonarr-api-key}
      '';
      # The gate's two secrets. oauth2-proxy reads them as env vars via
      # `keyFile`, so the values stay sealed and only the rendered file
      # lands in /run/secrets/rendered/.
      "oauth2-proxy.env" = envTemplate ''
        OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.oidc-gate-secret}
        OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.gate-cookie-secret}
      '';
    };

    services.fortress-client.adminPasswordEnvFile =
      lib.mkDefault config.sops.templates."fortress-admin.env".path;

    # The whole inventory must materialize: a missing key is a service that
    # starts with no credential and fails in a way that looks like a bug in
    # the service rather than in the inventory.
    assertions = [
      {
        assertion = lib.all (name: builtins.hasAttr name config.sops.secrets) (builtins.attrNames inventory);
        message = "fortress: the sops inventory is not fully materialized — every key in fortress.secrets._inventory must appear in sops.secrets";
      }
    ];
  };
}
