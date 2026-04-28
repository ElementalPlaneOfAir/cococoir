{...}: {
  # NOTE: Disabled for now, mainly since after a deep dive into mail deliverability, running your own email server seems next to fucking impossible :(
  #
  # Stalwart Mail Server — all-in-one SMTP, IMAP, JMAP, and webadmin.
  #
  # IMPORTANT PREREQUISITES:
  #   1. Reverse DNS (PTR) record for your VPS IP must point to
  #      the mail hostname (default: mail.<your-domain>), or at least
  #      to something that resolves forward/backward consistently.
  #      Set this in your VPS provider's control panel (IONOS).
  #   2. DNS MX record pointing to mail.<your-domain>.
  #   3. DNS A record for mail.<your-domain> pointing to your VPS IP.
  #   4. Port 25 is often blocked by VPS providers by default.
  #      You may need to open a support ticket with IONOS to unblock it.
  #   5. SPF, DKIM, and DMARC DNS records should be configured after
  #      Stalwart is running. The webadmin will show you the exact
  #      records to add.
  #   6. For production use, replace the self-signed TLS certificate
  #      with a proper ACME/Let's Encrypt certificate.
  #
  flake.modules.nixos.mailServer = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.cococoir.mail;
    domain = config.cococoir.publicDomain;
  in {
    options.cococoir.mail = {
      enable = lib.mkEnableOption "Stalwart mail server for inbound/outbound email";

      hostname = lib.mkOption {
        type = lib.types.str;
        default = "mail.${
          if domain != null
          then domain
          else config.networking.hostName
        }";
        description = ''
          Hostname used for the mail server. This should match the PTR/reverse
          DNS record of your public IP, and be the target of your MX record.
        '';
      };

      generateSelfSignedCert = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Generate a self-signed TLS certificate on first boot if no certificate
          exists at tlsCert/tlsKey. This lets Stalwart start immediately, but
          you should replace it with an ACME certificate for production.
        '';
      };

      tlsCert = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/stalwart/certs/${cfg.hostname}.crt";
        description = ''
          Path to the TLS certificate (PEM format).
          If you use security.acme, point this to the ACME certificate path.
        '';
      };

      tlsKey = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/stalwart/certs/${cfg.hostname}.key";
        description = ''
          Path to the TLS private key (PEM format).
          If you use security.acme, point this to the ACME key path.
        '';
      };
    };

    config = lib.mkIf cfg.enable {
      # ------------------------------------------------------------------
      # Self-signed certificate fallback (optional)
      # ------------------------------------------------------------------
      systemd.services.stalwart-gen-cert = lib.mkIf cfg.generateSelfSignedCert {
        description = "Generate self-signed TLS certificate for Stalwart if missing";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "stalwart-gen-cert" ''
            CERT_DIR="$(dirname ${cfg.tlsCert})"
            mkdir -p "$CERT_DIR"
            if [[ ! -f ${cfg.tlsCert} ]]; then
              ${lib.getExe pkgs.openssl} req -x509 -newkey rsa:4096 \
                -keyout ${cfg.tlsKey} \
                -out ${cfg.tlsCert} \
                -sha256 -days 365 \
                -nodes \
                -subj "/CN=${cfg.hostname}"
              chmod 640 ${cfg.tlsKey}
              chmod 644 ${cfg.tlsCert}
            fi
          '';
        };
        wantedBy = ["multi-user.target"];
        before = ["stalwart.service"];
      };

      # ------------------------------------------------------------------
      # Stalwart core configuration
      # ------------------------------------------------------------------
      services.stalwart = {
        enable = true;
        # Pin to the NixOS version when first enabled. Do not change later
        # or Stalwart may migrate storage formats unexpectedly.
        stateVersion = "24.11";

        settings = {
          # The hostname announced in SMTP banner, Message-Id, etc.
          server.hostname = cfg.hostname;

          # TLS certificate used by all listeners
          certificate."default" = {
            cert = "%{file:${cfg.tlsCert}}%";
            private-key = "%{file:${cfg.tlsKey}}%";
          };

          server.tls = {
            certificate = "default";
            enable = true;
            # Default to STARTTLS (explicit TLS). IMAPS listener overrides
            # this to implicit TLS on port 993.
            implicit = false;
          };

          # Listener configuration
          server.listener = {
            # SMTP inbound (tunneled from VPS:25)
            smtp = {
              bind = ["0.0.0.0:25"];
              protocol = "smtp";
            };

            # SMTP submission for authenticated outbound (tunneled from VPS:587)
            submission = {
              bind = ["0.0.0.0:587"];
              protocol = "smtp";
              tls.implicit = false;
            };

            # IMAPS for reading mail (tunneled from VPS:993)
            imaps = {
              bind = ["0.0.0.0:993"];
              protocol = "imap";
              # IMAPS conventionally uses implicit TLS on 993
              tls.implicit = true;
            };

            # HTTP for webadmin + JMAP API (proxied by Caddy)
            http = {
              bind = ["127.0.0.1:8080"];
              protocol = "http";
            };
          };

          # Use the built-in directory backed by RocksDB
          directory.internal.type = "internal";
          storage.directory = "internal";

          # Deliver locally by default; remote delivery uses DNS MX lookup
          queue.strategy.route = "local";

          # Allow relay from localhost without authentication so services
          # like Forgejo, Vaultwarden, and Matrix can send mail easily.
          # In production you may want to require SMTP AUTH instead.
          session.rcpt.relay = ["127.0.0.0/8" "[::1]/128"];
        };
      };

      # ------------------------------------------------------------------
      # Caddy reverse-proxy for Stalwart webadmin / JMAP
      # ------------------------------------------------------------------
      services.caddy.virtualHosts = {
        "${cfg.hostname}".extraConfig = ''
          reverse_proxy localhost:8080
        '';
      };

      # ------------------------------------------------------------------
      # Rathole client tunnels — forward VPS ports down to amon-sul
      # ------------------------------------------------------------------
      services.rathole.settings.client.services.smtp = {
        local_addr = "127.0.0.1:25";
        type = "tcp";
      };
      services.rathole.settings.client.services.submission = {
        local_addr = "127.0.0.1:587";
        type = "tcp";
      };
      services.rathole.settings.client.services.imaps = {
        local_addr = "127.0.0.1:993";
        type = "tcp";
      };
    };
  };
}
