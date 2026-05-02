{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.services.stalwart;
  domain = config.cococoir.domain;
in
{
  options.cococoir.services.stalwart = {
    enable = lib.mkEnableOption "Stalwart mail server (SMTP, IMAP, JMAP)";

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "mail.${if domain != null then domain else config.networking.hostName}";
      description = ''
        Hostname used for the mail server. This should match the PTR/reverse
        DNS record of your public IP, and be the target of your MX record.
      '';
    };

    globallyAccessible = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to tunnel mail ports through the VPS proxy.";
    };

    generateSelfSignedCert = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Generate a self-signed TLS certificate on first boot if no certificate
        exists. You should replace it with an ACME certificate for production.
      '';
    };

    tlsCert = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/stalwart/certs/${cfg.hostname}.crt";
    };

    tlsKey = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/stalwart/certs/${cfg.hostname}.key";
    };
  };

  config = lib.mkIf cfg.enable {
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
      wantedBy = [ "multi-user.target" ];
      before = [ "stalwart.service" ];
    };

    services.stalwart = {
      enable = true;
      stateVersion = "24.11";
      settings = {
        server.hostname = cfg.hostname;
        certificate.default = {
          cert = "%{file:${cfg.tlsCert}}%";
          private-key = "%{file:${cfg.tlsKey}}%";
        };
        server.tls = {
          certificate = "default";
          enable = true;
          implicit = false;
        };
        server.listener = {
          smtp = {
            bind = [ "0.0.0.0:25" ];
            protocol = "smtp";
          };
          submission = {
            bind = [ "0.0.0.0:587" ];
            protocol = "smtp";
            tls.implicit = false;
          };
          imaps = {
            bind = [ "0.0.0.0:993" ];
            protocol = "imap";
            tls.implicit = true;
          };
          http = {
            bind = [ "127.0.0.1:8080" ];
            protocol = "http";
          };
        };
        directory.internal.type = "internal";
        storage.directory = "internal";
        queue.strategy.route = "local";
        session.rcpt.relay = [ "127.0.0.0/8" "[::1]/128" ];
      };
    };

    services.caddy.virtualHosts = {
      "${cfg.hostname}".extraConfig = ''
        reverse_proxy localhost:8080
      '';
    };

    # Rathole client tunnels for mail ports
    cococoir.proxy.client.extraServices = lib.mkIf cfg.globallyAccessible {
      smtp = {
        local_addr = "127.0.0.1:25";
        type = "tcp";
      };
      submission = {
        local_addr = "127.0.0.1:587";
        type = "tcp";
      };
      imaps = {
        local_addr = "127.0.0.1:993";
        type = "tcp";
      };
    };
  };
}
