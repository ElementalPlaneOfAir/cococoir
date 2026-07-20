# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir/tls — the platform's TLS posture, read by the service
# contract factory's Caddy vhost builder.
#
# One option. Each service vhost picks up the right `tls` directive
# from here, so a customer does not write `tls <cert> <key>` into
# every vhost and does not learn about ACME unless they want to.
#
#   cococoir.tls = {
#     mode = "acme";           # production: Let's Encrypt via Caddy
#     # mode = "self-signed";  # dev VMs: pre-generated cert/key
#     # certFile = "/etc/..."; # required when mode = "self-signed"
#     # keyFile  = "/etc/...";
#   };
#
# Why this is platform-owned (not per-vhost):
#   - One decision, many vhosts. Nextcloud/Gitea/etc. inherit it.
#   - Production and dev differ in exactly one field (mode + files).
#   - mkDefault on the vhost `tls` directive means a user can still
#     override one vhost with a custom cert, e.g. a wildcard cert
#     the operator owns separately. Default wins, override is local.
{lib, config, ...}:

{
  options.cococoir.tls = {
    mode = lib.mkOption {
      type = lib.types.enum ["off" "acme" "self-signed"];
      default = "off";
      description = ''
        How Caddy obtains TLS certificates for cococoir vhosts.

        - `"off"`: no `tls` directive is emitted. Use for HTTP-only
          dev loops or behind another TLS terminator.
        - `"acme"`: Caddy auto-issues via ACME (Let's Encrypt by
          default). Production default; requires reachable DNS.
        - `"self-signed"`: a pre-generated cert + key are read from
          `certFile` / `keyFile`. Dev VMs and air-gapped setups.
      '';
    };

    certFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the PEM-encoded certificate. Required when
        `mode = "self-signed"`; ignored otherwise. In production
        this is the operator's wildcard cert; in dev VMs it is a
        build-time-generated `*.vmtest.local` cert.
      '';
    };

    keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the PEM-encoded private key. Same conditions as
        `certFile`.
      '';
    };
  };

  config = lib.mkIf (config.cococoir.tls.mode == "self-signed") {
    assertions = [
      {
        assertion = config.cococoir.tls.certFile != null;
        message = ''
          cococoir.tls: certFile is required when mode = "self-signed".
        '';
      }
      {
        assertion = config.cococoir.tls.keyFile != null;
        message = ''
          cococoir.tls: keyFile is required when mode = "self-signed".
        '';
      }
    ];
  };
}
