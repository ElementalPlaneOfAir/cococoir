{...}: {
  flake.modules.nixos.mediaServer = {
    pkgs,
    config,
    inputs,
    lib,
    ...
  }: let
    domain = config.cococoir.publicDomain;
    vps = config.cococoir.vpsAddress;
    machineName = config.networking.hostName;
  in {
    options.cococoir.publicDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public domain used for exposing services via reverse proxy and ACME.";
    };

    options.cococoir.vpsAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public IP address or domain of the VPS running the rathole server.";
    };

    config = {
      virtualisation.docker.enable = lib.mkForce false;

      services.jellyfin = {
        enable = true;
        openFirewall = false;
        user = "jellyfin";
      };

      services.cryptpad = {
        enable = true;
        settings = {
          httpPort = 9000;
          httpAddress = "127.0.0.1";
          # Ideally it would be nice to include cryptpad.amon-sul.internal as an extra interface for these components.
          httpUnsafeOrigin = "https://cryptpad.${domain}";
          httpSafeOrigin = "https://cryptpad.${domain}";
          # NOTE: For full CryptPad security isolation, httpSafeOrigin should be a
          # separate subdomain (e.g. https://cryptpad-sandbox.<domain>).
        };
      };

      services.forgejo = {
        enable = true;
        settings = {
          server = {
            DOMAIN = "git.${domain}";
            ROOT_URL = "https://git.${domain}";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = 3000;
          };
        };
      };

      services.matrix-continuwuity = {
        enable = true;
        settings = {
          global = {
            server_name = "${domain}";
            address = ["127.0.0.1"];
            port = [6167];
          };
        };
      };

      services.vaultwarden = {
        enable = true;
        config = {
          DOMAIN = "https://vault.${domain}";
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = 8222;
          SIGNUPS_ALLOWED = true;
        };
      };

      clan.core.vars.generators.privado-wireguard = {
        prompts.wireguard-conf = {
          description = "Paste your Privado VPN WireGuard configuration";
          type = "multiline";
          persist = true;
        };
      };

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "enp11s0";
          bind-interfaces = true;
          server = ["8.8.8.8" "1.1.1.1"];
          address = ["/${machineName}.internal/192.168.0.7" "/${domain}/192.168.0.7"];
        };
      };

      services.caddy = {
        enable = true;
        # globalConfig = ''
        #   auto_https off
        # '';
        virtualHosts = {
          "http://jellyfin.${machineName}.internal".extraConfig = ''
            reverse_proxy localhost:8096
          '';
          "http://cryptpad.${machineName}.internal".extraConfig = ''
            reverse_proxy localhost:9000
          '';
          "http://git.${machineName}.internal".extraConfig = ''
            reverse_proxy localhost:3000
          '';
          "http://matrix.${machineName}.internal".extraConfig = ''
            reverse_proxy localhost:6167
          '';
          "http://vault.${machineName}.internal".extraConfig = ''
            reverse_proxy localhost:8222
          '';
          "${domain}".extraConfig = ''
            handle_path /.well-known/matrix/server {
              header Content-Type application/json
              respond "{\"m.server\": \"matrix.${domain}:443\"}"
            }
            handle_path /.well-known/matrix/client {
              header Content-Type application/json
              respond "{\"m.homeserver\": {\"base_url\": \"https://matrix.${domain}\"}}"
            }
            redir https://jellyfin.${domain}{uri} permanent
          '';
          "jellyfin.${domain}".extraConfig = ''
            reverse_proxy localhost:8096
          '';
          "cryptpad.${domain}".extraConfig = ''
            reverse_proxy localhost:9000
          '';
          "git.${domain}".extraConfig = ''
            reverse_proxy localhost:3000
          '';
          "matrix.${domain}".extraConfig = ''
            reverse_proxy localhost:6167
          '';
          "vault.${domain}".extraConfig = ''
            reverse_proxy localhost:8222
          '';
          # Transmission not secure on an external domain
          # "transmission.${domain}".extraConfig = ''
          #   reverse_proxy localhost:9091
          # '';
        };
      };

      services.rathole = {
        enable = true;
        role = "client";
        settings = {
          client = {
            remote_addr = "${vps}:2333";
          };
          client.services.http = {
            local_addr = "127.0.0.1:80";
          };
          client.services.https = {
            local_addr = "127.0.0.1:443";
          };
          client.services.https_udp = {
            local_addr = "127.0.0.1:443";
            type = "udp";
          };
        };
        credentialsFile = config.clan.core.vars.generators.rathole-tokens.files.client-tokens.path;
      };

      networking.firewall.allowedTCPPorts = [53 80 111 2049 4000 4001 4002 443 20048 51413];
      networking.firewall.allowedUDPPorts = [53 80 111 2049 4000 4001 4002 443 20048 51413];
      users.groups.jellyfin = {};
      users.users.jellyfin = {
        isSystemUser = true;
        description = "Jellyfin System User";
        shell = pkgs.bashInteractive;
        extraGroups = ["render" "video"];
      };

      services.gvfs.enable = true;
      services.udisks2.enable = true;

      services.nfs.server.enable = true;

      virtualisation.containers = {
        enable = true;
        registries.search = ["docker.io"];
        policy = {
          default = [{type = "insecureAcceptAnything";}];
          transports = {
            docker-daemon = {
              "" = [{type = "insecureAcceptAnything";}];
            };
          };
        };
      };

      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };

      environment.systemPackages = with pkgs; [
        jellyfin
        jellyfin-web
        jellyfin-ffmpeg
        wireguard-tools
        dive
        podman-tui
        docker-compose
        podman-compose
      ];
    };
  };
}
