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
    services.caddy.virtualHosts = {
      "http://transmission.${machineName}.internal".extraConfig = ''
        reverse_proxy localhost:9091
      '';
    };
  };
}
