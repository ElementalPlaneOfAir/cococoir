# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fortress vmtest-wiring check.
#
# L1: pure option-tree evaluation against the *actual* vmtest
# nixosConfiguration. No VM, no QEMU. Catches the regression
# class where an OIDC integration silently vanishes from the
# rendered config — e.g. a lib.mkForce discarding the
# integration's definitions, or missing boot activation.
#
# Why evaluate vmtest instead of a synthetic config: the bug
# this guards against lived in the composition of vmtest.nix
# with the fortress modules, not in any single module. Only
# the real composition is a faithful tripwire.
{pkgs, vmtestConfig}:
let
  lib = pkgs.lib;

  # ── dashboard.nix extraction ─────────────────────────────────
  # The service enables live in nixosConfigurations/dashboard.nix
  # (the customer-edited file). A silent drop of one during a refactor
  # would disable a service with no trace — assert they all render.
  dashboardServices = ["jellyfin" "cryptpad" "media"];
  dashboardServiceEnabled = name:
    vmtestConfig.fortress.services.${name}.enable or false;

  # ── jellyfin OIDC ────────────────────────────────────────────
  jellarrCfg = vmtestConfig.services.jellarr;
  plugins = jellarrCfg.config.plugins or null;
  branding = jellarrCfg.config.branding or null;
  folderNames = map (f: f.name) jellarrCfg.config.library.virtualFolders;
  folderPaths = lib.concatMap (f: map (p: p.path) (f.libraryOptions.pathInfos or []))
    jellarrCfg.config.library.virtualFolders;
  movieLibraryPath = let
    folder = lib.findFirst (f: f.name == "Movies") null jellarrCfg.config.library.virtualFolders;
  in if folder == null then null else (builtins.head folder.libraryOptions.pathInfos).path;
  mediaSubvolumes = vmtestConfig.fortress.storage.btrfs.subvolumes;
  movieDirs = builtins.attrNames (mediaSubvolumes."media-movies".dirs or {});
  showDirs = builtins.attrNames (mediaSubvolumes."media-shows".dirs or {});

  # ── cryptpad OIDC ───────────────────────────────────────────
  cpSettings = vmtestConfig.services.cryptpad.settings;
  cpSso = cpSettings.sso or {};
  cpSsoProviders = cpSso.list or [];
  dexProvider = lib.findFirst (p: p.name == "dex") null cpSsoProviders;
  dexStaticClients = vmtestConfig.services.dex.settings.staticClients or [];
  cryptpadDexClient = lib.findFirst (c: c.id == "cryptpad") null dexStaticClients;
  cryptpadSecretSvc = vmtestConfig.systemd.services.fortress-cryptpad-oidc-secret;
  cryptpadSvcEnv = vmtestConfig.systemd.services.cryptpad.serviceConfig.Environment or [];
  hasCryptpadConfigEnv = lib.any (e: lib.hasPrefix "CRYPTPAD_CONFIG=" e) cryptpadSvcEnv;
  hasCryptpadSSOConfigEnv = lib.any (e: lib.hasPrefix "CRYPTPAD_SSO_CONFIG=" e) cryptpadSvcEnv;
  cryptpadPkg = vmtestConfig.services.cryptpad.package;
  cryptpadPkgHasSSO = lib.strings.hasInfix "-with-sso" (cryptpadPkg.name or "");

  # ── ingress / ACME ordering ──────────────────────────────────  # Caddy terminates ACME for every customer domain and those
  # challenges traverse the tunnel. If caddy.service doesn't order
  # after the client, a fresh boot races the tunnel and ACME backoff
  # leaves domains certless (auth/cryptpad incident, 2026-08-28).
  caddyOrdersAfterClient = builtins.elem "fortress-client.service"
    (vmtestConfig.systemd.services.caddy.after or []);

  # ── LAN access plane (ADR-028) ───────────────────────────────
  # The silent seam: dnsmasq answers service domains with the LAN
  # address, but if the factory's Caddy bind refactor regresses
  # (hardcoded `bind 127.0.0.1 ::1` again), LAN traffic hits a
  # closed port — correct DNS, dead ingress, invisible in DNS-only
  # checks. Assert BOTH sides render, from the real composition.
  lanAddress = vmtestConfig.fortress.network.lanAddress;
  lanDnsEnabled = vmtestConfig.fortress.network.dns.enable;
  dnsmasqAddresses = vmtestConfig.services.dnsmasq.settings.address or [];
  enabledServiceCfgs = lib.filterAttrs (_: s: (s.enable or false) && (s ? domain))
    vmtestConfig.fortress.services;
  enabledDomains = lib.mapAttrsToList (_: s: s.domain) enabledServiceCfgs;
  everyDomainAnswered = builtins.all
    (d: builtins.elem "/${d}/${lanAddress}" dnsmasqAddresses)
    enabledDomains;
  canaryAnswered = builtins.elem "/use-application-dns.net/" dnsmasqAddresses;
  everyVhostBindsLan = builtins.all (d:
    lib.hasInfix "bind 127.0.0.1 ::1 ${lanAddress}"
      vmtestConfig.services.caddy.virtualHosts."${d}".extraConfig)
    enabledDomains;

  # ── media automation stack ───────────────────────────────────
  mediaStackServices = ["radarr" "sonarr" "qbittorrent" "seerr"];
  mediaServiceEnabled = name: vmtestConfig.fortress.services.${name}.enable;
  mediaApplySvc = vmtestConfig.systemd.services.fortress-media-apply or null;
  mediaKeygenSvc = vmtestConfig.systemd.services.fortress-media-api-keys or null;
  qbittorrentCfg = vmtestConfig.services.qbittorrent;
  qbittorrentFortressCfg = vmtestConfig.fortress.services.qbittorrent;
in
# ── dashboard.nix assertions ──────────────────────────────────
# Every service declared in the customer-edited dashboard.nix must
# render enabled in the real composition.
assert lib.assertMsg (builtins.all dashboardServiceEnabled dashboardServices)
  "vmtest-wiring: a service enable from nixosConfigurations/dashboard.nix was dropped from the rendered config — the dashboard.nix extraction is broken";

# ── media automation stack assertions ─────────────────────────
# The single `media` toggle must render ALL four services plus the
# keygen + apply oneshots — a silent drop anywhere in that chain
# yields a half-wired stack that looks healthy in every per-service
# check.
assert lib.assertMsg (builtins.all mediaServiceEnabled mediaStackServices)
  "vmtest-wiring: the media toggle did not render all four media stack services enabled";
assert lib.assertMsg (mediaApplySvc != null && builtins.elem "multi-user.target" (mediaApplySvc.wantedBy or []))
  "vmtest-wiring: fortress-media-apply is missing or has no boot activation — the stack would boot unwired";
assert lib.assertMsg (mediaApplySvc != null && builtins.all (u: builtins.elem u (mediaApplySvc.after or [])) ["radarr.service" "sonarr.service" "qbittorrent.service" "fortress-media-api-keys.service"])
  "vmtest-wiring: fortress-media-apply does not order after the media services — it could apply against half-up services";
assert lib.assertMsg (mediaKeygenSvc != null && builtins.elem "multi-user.target" (mediaKeygenSvc.wantedBy or []))
  "vmtest-wiring: fortress-media-api-keys is missing or has no boot activation — *arr API keys would never be pinned";
assert lib.assertMsg (qbittorrentCfg.enable)
  "vmtest-wiring: services.qbittorrent is not enabled";
assert lib.assertMsg (qbittorrentFortressCfg.public == false)
  "vmtest-wiring: qbittorrent's Caddy vhost is public — the web UI must stay the internal admin surface (seerr is the front door)";
assert lib.assertMsg (vmtestConfig.systemd.services.qbittorrent.serviceConfig.PrivateUsers or null == false)
  "vmtest-wiring: qbittorrent.service still has PrivateUsers=true — supplementary-group mapping to nobody would silently revoke access to the 0770 media subvolumes";
assert lib.assertMsg (qbittorrentCfg.group == "jellyfin")
  "vmtest-wiring: qbittorrent does not run in the jellyfin group — it could not write the media subvolume downloads dirs";
# ── jellyfin assertions ────────────────────────────────────────
assert lib.assertMsg (jellarrCfg.enable)
  "vmtest-wiring: services.jellarr is not enabled — the jellyfin service module must activate it";
assert lib.assertMsg (plugins != null)
  "vmtest-wiring: services.jellarr.config.plugins is null — the jellyfin-oidc integration was dropped (lib.mkForce on services.jellarr.config?)";
assert lib.assertMsg (branding != null)
  "vmtest-wiring: services.jellarr.config.branding is null — the jellyfin-oidc login button was dropped";
assert lib.assertMsg (builtins.elem "Movies" folderNames)
  "vmtest-wiring: vmtest's virtualFolders override did not apply";
assert lib.assertMsg (!(builtins.elem "Entertainment" folderNames))
  "vmtest-wiring: the jellyfin module's mkDefault virtualFolders leaked into vmtest (should be overridden)";
assert lib.assertMsg (builtins.elem "multi-user.target" vmtestConfig.systemd.services.jellarr.wantedBy)
  "vmtest-wiring: jellarr.service has no boot activation — declarative config would never apply on first boot";

# ── media library layout assertions ───────────────────────────
# Jellyfin must scan the `library/` subdir of each media subvolume,
# never the subvolume root — the `downloads/` staging area lives
# beside it, and a root scan would surface in-flight, misnamed
# torrents in the user's library (the "library lies" failure).
assert lib.assertMsg (movieLibraryPath != null && lib.hasSuffix "/library" movieLibraryPath)
  "vmtest-wiring: the Movies library does not point at a /library subdir (got: ${toString movieLibraryPath}) — raw downloads would leak into the Jellyfin library";
assert lib.assertMsg (builtins.all (p: lib.hasSuffix "/library" p) (lib.filter (p: lib.hasInfix "/movies/" p || lib.hasInfix "/shows/" p) folderPaths))
  "vmtest-wiring: a movie/show Jellyfin library path does not point at a /library subdir — raw downloads would leak into the library";
assert lib.assertMsg (builtins.elem "${mediaSubvolumes."media-movies".mountpoint}/downloads" movieDirs && builtins.elem "${mediaSubvolumes."media-movies".mountpoint}/library" movieDirs)
  "vmtest-wiring: the media-movies subvolume does not declare downloads/ + library/ dirs — the hardlink staging layout is missing";
assert lib.assertMsg (builtins.elem "${mediaSubvolumes."media-shows".mountpoint}/downloads" showDirs && builtins.elem "${mediaSubvolumes."media-shows".mountpoint}/library" showDirs)
  "vmtest-wiring: the media-shows subvolume does not declare downloads/ + library/ dirs — the hardlink staging layout is missing";

# ── cryptpad assertions ───────────────────────────────────────
assert lib.assertMsg (cpSso.enabled or false)
  "vmtest-wiring: cryptpad SSO is not enabled — the cryptpad-oidc integration was dropped";
assert lib.assertMsg (cpSso.enforced or false)
  "vmtest-wiring: cryptpad SSO is not enforced — local password login would be allowed";
assert lib.assertMsg (cpSso.cpPassword or false)
  "vmtest-wiring: cryptpad SSO has cpPassword disabled — users could not set an encryption password at registration";
assert lib.assertMsg (dexProvider != null)
  "vmtest-wiring: cryptpad SSO provider list has no 'dex' entry — OIDC provider not wired";
assert lib.assertMsg (dexProvider != null && dexProvider.client_id == "cryptpad")
  "vmtest-wiring: cryptpad OIDC client_id is not 'cryptpad'";
assert lib.assertMsg (dexProvider != null && dexProvider.url != null)
  "vmtest-wiring: cryptpad OIDC provider URL is null";
assert lib.assertMsg (cryptpadDexClient != null)
  "vmtest-wiring: dex staticClients has no 'cryptpad' entry — client registration was dropped";
assert lib.assertMsg (cryptpadDexClient != null && builtins.elem "https://${vmtestConfig.fortress.services.cryptpad.domain}/ssoauth" (cryptpadDexClient.redirectURIs or []))
  "vmtest-wiring: cryptpad dex client redirect URI mismatch";
assert lib.assertMsg (cryptpadSecretSvc.wantedBy != null && builtins.elem "multi-user.target" cryptpadSecretSvc.wantedBy)
  "vmtest-wiring: fortress-cryptpad-oidc-secret has no boot activation";
assert lib.assertMsg hasCryptpadConfigEnv
  "vmtest-wiring: cryptpad.service has no CRYPTPAD_CONFIG env var — the oidc config is not wired";
assert lib.assertMsg hasCryptpadSSOConfigEnv
  "vmtest-wiring: cryptpad.service has no CRYPTPAD_SSO_CONFIG env var — the SSO plugin config is not wired";
assert lib.assertMsg cryptpadPkgHasSSO
  "vmtest-wiring: cryptpad package is the vanilla nixpkgs cryptpad (no -with-sso suffix) — the SSO plugin override was dropped";

# ── ingress ordering assertion ────────────────────────────────
assert lib.assertMsg caddyOrdersAfterClient
  "vmtest-wiring: caddy.service does not order after fortress-client.service — fresh boots race the tunnel and ACME backoff leaves customer domains certless";

# ── LAN access plane assertions (ADR-028) ─────────────────────
assert lib.assertMsg (lanAddress == "10.0.2.15" && lanDnsEnabled)
  "vmtest-wiring: vmtest does not set fortress.network.lanAddress — the LAN DNS plane is not exercised by the suite";
assert lib.assertMsg everyDomainAnswered
  "vmtest-wiring: dnsmasq does not answer every enabled service domain with the LAN address (got: ${builtins.toJSON dnsmasqAddresses}) — the LAN DNS enumeration dropped a service";
assert lib.assertMsg canaryAnswered
  "vmtest-wiring: dnsmasq does not NXDOMAIN the Firefox DoH canary (use-application-dns.net) — secure-DNS browsers bypass the split-horizon";
assert lib.assertMsg (vmtestConfig.services.dnsmasq.resolveLocalQueries == false)
  "vmtest-wiring: dnsmasq resolveLocalQueries is on — the box's own resolver would be hijacked by its LAN DNS layer";
assert lib.assertMsg everyVhostBindsLan
  "vmtest-wiring: an enabled vhost does not bind the LAN address — dnsmasq answers with a closed port (correct DNS, dead ingress)";
{
  vmtest-wiring = pkgs.runCommand "fortress-vmtest-wiring" {} ''
    cat > $out <<EOF
    fortress vmtest-wiring: PASS
      jellyfin: OIDC wired (plugins + branding), jellarr boot-activated
      cryptpad: OIDC wired (SSO enabled + enforced, dex client registered, secret oneshot boot-activated, CRYPTPAD_CONFIG env set, SSO plugin bundled in package)
      ingress: caddy.service orders after fortress-client.service (ACME over the tunnel)
      LAN DNS: dnsmasq answers every enabled service domain with ${lanAddress}, DoH canary NXDOMAINs, every vhost binds the LAN address
    EOF
  '';
}
