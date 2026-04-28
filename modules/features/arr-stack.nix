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
        # Disable the whitelist so *arr apps can connect via the bridge address.
        rpc-whitelist-enabled = false;
        peer-port = 51413;
        download-dir = "/media/entertain";
      };
    };

    # -------------------------------------------------------------------------
    # Fully integrated *arr stack
    # -------------------------------------------------------------------------
    # Prowlarr manages indexers and syncs them to the other *arr apps.
    # It does not need filesystem access to /media, so we leave it as a
    # dynamic user for simplicity.
    services.prowlarr = {
      enable = true;
      openFirewall = false;
      settings.server.bindaddress = "127.0.0.1";
    };

    # Radarr, Sonarr, Lidarr and Bazarr all need read/write access to /media
    # so they run as the jellyfin user for seamless file sharing with
    # Transmission and Jellyfin.
    services.radarr = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
      group = "jellyfin";
      settings.server.bindaddress = "127.0.0.1";
    };

    services.sonarr = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
      group = "jellyfin";
      settings.server.bindaddress = "127.0.0.1";
    };

    services.lidarr = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
      group = "jellyfin";
      settings.server.bindaddress = "127.0.0.1";
    };

    services.bazarr = {
      enable = true;
      openFirewall = false;
      user = "jellyfin";
      group = "jellyfin";
    };

    # Pre-create media directories with jellyfin ownership so the apps can
    # organise downloads immediately.  Existing /media/entertain is left as-is.
    systemd.tmpfiles.rules = [
      "d /media/movies   0775 jellyfin jellyfin -"
      "d /media/tv       0775 jellyfin jellyfin -"
      "d /media/music    0775 jellyfin jellyfin -"
      "d /media/entertain 0775 jellyfin jellyfin -"
    ];

    services.caddy.virtualHosts = {
      # Transmission lives inside the VPN namespace; reach it through the
      # bridge address instead of localhost.
      "http://transmission.${machineName}.internal".extraConfig = ''
        reverse_proxy 192.168.15.1:9091
      '';
      "http://prowlarr.${machineName}.internal".extraConfig = ''
        reverse_proxy localhost:9696
      '';
      "http://radarr.${machineName}.internal".extraConfig = ''
        reverse_proxy localhost:7878
      '';
      "http://sonarr.${machineName}.internal".extraConfig = ''
        reverse_proxy localhost:8989
      '';
      "http://lidarr.${machineName}.internal".extraConfig = ''
        reverse_proxy localhost:8686
      '';
      "http://bazarr.${machineName}.internal".extraConfig = ''
        reverse_proxy localhost:6767
      '';
    };
  };
}
