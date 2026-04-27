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
    hasPublic = domain != null && vps != null;
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
          httpUnsafeOrigin =
            if hasPublic
            then "https://cryptpad.${domain}"
            else "http://localhost:${toString config.services.cryptpad.settings.httpPort}";
          httpSafeOrigin =
            if hasPublic
            then "https://cryptpad.${domain}"
            else "http://localhost:${toString config.services.cryptpad.settings.httpPort}";
          # NOTE: For full CryptPad security isolation, httpSafeOrigin should be a
          # separate subdomain (e.g. https://cryptpad-sandbox.<domain>).
        };
      };

      clan.core.vars.generators.privado-wireguard = {
        prompts.wireguard-conf = {
          description = "Paste your Privado VPN WireGuard configuration";
          type = "multiline";
          persist = true;
        };
      };

      vpnNamespaces.wg = {
        enable = true;
        wireguardConfigFile = config.clan.core.vars.generators.privado-wireguard.files.wireguard-conf.path;
        accessibleFrom = ["127.0.0.1"];
        portMappings = [
          {
            from = 9091;
            to = 9091;
          }
        ];
        openVPNPorts = [
          {
            port = 51413;
            protocol = "both";
          }
        ];
      };

      systemd.services.transmission.vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };

      services.transmission = {
        enable = true;
        package = pkgs.transmission_4;
        openRPCPort = false;
        openPeerPorts = true;
        user = "jellyfin";
        group = "jellyfin";
        settings = {
          rpc-bind-address = "192.168.15.1";
          rpc-whitelist = "127.0.0.1";
          peer-port = 51413;
          download-dir = "/media/entertain";
        };
      };

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "enp11s0";
          bind-interfaces = true;
          server = ["8.8.8.8" "1.1.1.1"];
          address = "/amon-sul.internal/192.168.0.7";
        };
      };

      services.caddy = {
        enable = true;
        globalConfig = lib.mkIf (!hasPublic) ''
          auto_https off
        '';
        virtualHosts = lib.mkMerge [
          (lib.mkIf (!hasPublic) {
            "http://jellyfin.amon-sul.internal".extraConfig = ''
              reverse_proxy localhost:8096
            '';
            "http://cryptpad.amon-sul.internal".extraConfig = ''
              reverse_proxy localhost:9000
            '';
            "http://transmission.amon-sul.internal".extraConfig = ''
              reverse_proxy localhost:9091
            '';
          })
          (lib.mkIf hasPublic {
            "${domain}".extraConfig = ''
              redir https://jellyfin.${domain}{uri} permanent
            '';
            "jellyfin.${domain}".extraConfig = ''
              reverse_proxy localhost:8096
            '';
            "cryptpad.${domain}".extraConfig = ''
              reverse_proxy localhost:9000
            '';
            "transmission.${domain}".extraConfig = ''
              reverse_proxy localhost:9091
            '';
          })
        ];
      };

      services.rathole = lib.mkIf hasPublic {
        enable = true;
        role = "client";
        settings = {
          client = {
            remote_addr = "${vps}:2333";
            transport.type = "noise";
          };
          client.services.http = {
            local_addr = "127.0.0.1:80";
          };
          client.services.https = {
            local_addr = "127.0.0.1:443";
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
