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
{pkgs, vmtestConfig, vmtestSystem}:
let
  lib = pkgs.lib;

  # ── dashboard port-collision tripwire ─────────────────────────
  # The dashboard binds a loopback port that must not collide with a
  # catalog service port (cryptpad owns 3000, forgejo 3001, ...).
  # client.nix asserts that, but an assertion nobody exercises is a
  # dead tripwire: prove it fires on a forced collision AND that the
  # shipped default collides with nothing the composition enables.
  clientEval = extra:
    vmtestSystem.extendModules {
      modules = [
        {
          services.fortress-client =
            {
              enable = true;
              adminPasswordEnvFile = "/etc/fortress-admin.env";
            }
            // extra;
        }
      ];
    };
  collisionAssertionFires = eval: builtins.any
    (a: !a.assertion && lib.hasInfix "shares its port" a.message)
    eval.config.assertions;
  dashboardDefaultCollides = collisionAssertionFires (clientEval {});
  forcedCollisionFires = collisionAssertionFires (clientEval {dashboardAddr = "127.0.0.1:3000";});

  # ── dashboard.nix extraction ─────────────────────────────────
  # The service enables live in nixosConfigurations/dashboard.nix
  # (the customer-edited file). A silent drop of one during a refactor
  # would disable a service with no trace — assert they all render.
  dashboardServices = ["jellyfin" "cryptpad" "media" "forgejo"];
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
  # address, but if the factory's Caddy bind regresses to a
  # localhost-only list (`bind 127.0.0.1 ::1`), LAN/tailnet traffic
  # hits a closed port — correct DNS, dead ingress, invisible in
  # DNS-only checks. Assert BOTH sides render, from the real
  # composition.
  lanAddress = vmtestConfig.fortress.network.lanAddress;
  lanDnsEnabled = vmtestConfig.fortress.network.dns.enable;
  dnsmasqAddresses = vmtestConfig.fortress.network.dns.addresses;
  dnsUnit = vmtestConfig.systemd.services.fortress-dns;
  dnsExec = dnsUnit.serviceConfig.ExecStart or "";
  enabledServiceCfgs = lib.filterAttrs (_: s: (s.enable or false) && (s ? domain))
    vmtestConfig.fortress.services;
  enabledDomains = lib.mapAttrsToList (_: s: s.domain) enabledServiceCfgs;
  everyDomainAnswered = builtins.all
    (d: builtins.elem "/${d}/${lanAddress}" dnsmasqAddresses)
    enabledDomains;
  canaryAnswered = builtins.elem "/use-application-dns.net/" dnsmasqAddresses;
  everyVhostBindsWildcard = builtins.all (d:
    lib.hasInfix "bind 0.0.0.0 ::"
      vmtestConfig.services.caddy.virtualHosts."${d}".extraConfig)
    enabledDomains;
  # The LAN plane is a :80 catch-all: any hostname (the box's IP, its
  # machine name, anything the LAN resolves) serves the dashboard over
  # plain HTTP. If this vhost silently vanishes, typing the box's IP
  # 404s and the customer has no zero-config way in — invisible to
  # every per-service check.
  dashboardAddr = vmtestConfig.services.fortress-client.dashboardAddr;
  lanDashboardVhost = vmtestConfig.services.caddy.virtualHosts.":80" or null;
  caddyGlobalConfig = vmtestConfig.services.caddy.globalConfig or "";
  clearnetRedirectVhost = host:
    vmtestConfig.services.caddy.virtualHosts."http://${host}" or null;

  # ── claim-flow boot tripwire (claim-flow T7) ──────────────────
  # vmtest-bootstrap.sh's claim-flow section only bites when the e2e
  # runs; if the client (or its claimable config) silently drops out
  # of the vmtest composition, the boot-dead-end guard is gone and
  # nothing else in L1 would notice.
  clientEnabled = vmtestConfig.services.fortress-client.enable or false;
  clientConfigJson = builtins.toJSON (vmtestConfig.services.fortress-client.settings or {});
  claimableConfig = lib.hasInfix "{tunnel_ip}" clientConfigJson;

  # ── media automation stack ───────────────────────────────────
  mediaStackServices = ["radarr" "sonarr" "qbittorrent" "seerr"];
  mediaServiceEnabled = name: vmtestConfig.fortress.services.${name}.enable;
  mediaApplySvc = vmtestConfig.systemd.services.fortress-media-apply or null;
  mediaKeygenSvc = vmtestConfig.systemd.services.fortress-media-api-keys or null;
  qbittorrentCfg = vmtestConfig.services.qbittorrent;
  qbittorrentFortressCfg = vmtestConfig.fortress.services.qbittorrent;

  # ── path-routing matrix (ADR-034) ────────────────────────────
  # The failover matrix renders from planes.nix: one site per plane,
  # every service at `/<path>` on each, and each service's
  # non-canonical shape307s to its canonical. The silent seams: a
  # dropped plane row (service unreachable at its uniform entry
  # point), a lost issuer Location rewrite (SSO dead-ends on
  # loopback), and a lost cookie Path scope (apps collide on a
  # shared origin).
  dexIssuer = vmtestConfig.services.dex.settings.issuer or null;
  baseDomain = vmtestConfig.fortress.baseDomain;
  i2pPlaneHost = "${builtins.head (lib.splitString "." baseDomain)}.i2p";
  baseEscaped = lib.replaceStrings ["."] ["\\."] baseDomain;
  jfDomain = vmtestConfig.fortress.services.jellyfin.domain;
  jfPath = vmtestConfig.fortress.services.jellyfin.path;
  jfI2p = vmtestConfig.fortress.services.jellyfin.i2pDomain;
  clearnetPlane = vmtestConfig.services.caddy.virtualHosts."${baseDomain}".extraConfig or "";
  lanPlane = vmtestConfig.services.caddy.virtualHosts.":80".extraConfig or "";
  i2pPlane = vmtestConfig.services.caddy.virtualHosts."http://${i2pPlaneHost}".extraConfig or "";
  jellyfinVhost = vmtestConfig.services.caddy.virtualHosts."${jfDomain}".extraConfig or "";
  jellyfinI2pVhost = vmtestConfig.services.caddy.virtualHosts."http://${jfI2p}".extraConfig or null;
  jellyfinDexClient = lib.findFirst (c: c.id == "jellyfin") null dexStaticClients;
  seerrCfg = vmtestConfig.fortress.services.seerr;
  cryptpadCfg = vmtestConfig.fortress.services.cryptpad;
  seerrPortSite = vmtestConfig.services.caddy.virtualHosts."http://${lanAddress}:${toString seerrCfg.port}".extraConfig or null;
  cryptpadPortSite = vmtestConfig.services.caddy.virtualHosts."http://${lanAddress}:${toString cryptpadCfg.port}".extraConfig or null;
  routableEnabled =
    lib.filterAttrs (_: s: (s.enable or false) && (s ? path) && (s ? routing))
    vmtestConfig.fortress.services;
  rowIn = plane: name: s:
    lib.hasInfix "@row-${name} path ${s.path} ${s.path}/*" plane;
  pathRoutedNames = lib.attrNames (lib.filterAttrs (_: s: s.routing == "path") routableEnabled);

  # ── forgejo OIDC ─────────────────────────────────────────────
  forgejoCfg = vmtestConfig.fortress.services.forgejo;
  forgejoSettings = vmtestConfig.services.forgejo.settings.server;
  forgejoDexClient = lib.findFirst (c: c.id == "forgejo") null dexStaticClients;
  forgejoBootstrap = vmtestConfig.systemd.services.fortress-forgejo-oidc-bootstrap or null;
  forgejoVhost = vmtestConfig.services.caddy.virtualHosts."${forgejoCfg.domain}".extraConfig or "";
  forgejoI2pVhost = vmtestConfig.services.caddy.virtualHosts."http://${forgejoCfg.i2pDomain}".extraConfig or null;
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
assert lib.assertMsg (mediaApplySvc != null && builtins.all (u: builtins.elem u (mediaApplySvc.after or [])) ["radarr.service" "sonarr.service" "qbittorrent.service" "sops-install-secrets.service"])
  "vmtest-wiring: fortress-media-apply does not order after the media services + sops-install-secrets — it could apply against half-up services or with no secrets";
# Secrets are sealed, never minted. A reintroduced minting oneshot is the
# bug that made every rebuild rotate every key (2026-10-08).
assert lib.assertMsg (mediaKeygenSvc == null)
  "vmtest-wiring: fortress-media-api-keys is back — API keys must come from the sealed inventory (secrets.nix), not be minted at boot";
# Mechanism-agnostic: on NixOS sops-nix may install via the activation
# script or via sops-install-secrets, and the two disagree about which
# target pulls them in. What must hold is that the *whole* inventory is
# declared and pointed at a real sealed file — otherwise a key is missing
# and the consumer starts with no credential.
assert lib.assertMsg (vmtestConfig.sops.defaultSopsFile != null)
  "vmtest-wiring: sops.defaultSopsFile is unset — nothing decrypts the sealed inventory";
assert lib.assertMsg (lib.all (n: builtins.hasAttr n vmtestConfig.sops.secrets) (builtins.attrNames vmtestConfig.fortress.secrets._inventory))
  "vmtest-wiring: the sops inventory is not fully declared in sops.secrets — a consumer would start with no credential";
assert lib.assertMsg (qbittorrentCfg.enable)
  "vmtest-wiring: services.qbittorrent is not enabled";
assert lib.assertMsg (qbittorrentFortressCfg.public == false)
  "vmtest-wiring: qbittorrent's Caddy vhost is public — the web UI must stay the internal admin surface (seerr is the front door)";
assert lib.assertMsg (vmtestConfig.systemd.services.qbittorrent.serviceConfig.PrivateUsers or null == false)
  "vmtest-wiring: qbittorrent.service still has PrivateUsers=true — supplementary-group mapping to nobody would silently revoke access to the 0770 media subvolumes";
assert lib.assertMsg (qbittorrentCfg.user == "root" && qbittorrentCfg.group == "root")
  "vmtest-wiring: qbittorrent no longer runs as root — per ADR-036 it must, because the applier cannot create the qbittorrent/jellyfin accounts its unit would name";
# ── jellyfin assertions ────────────────────────────────────────
assert lib.assertMsg (vmtestConfig.services.jellyfin.user == "root" && vmtestConfig.services.jellyfin.group == "root")
  "vmtest-wiring: jellyfin no longer runs as root — per ADR-036 it must, because the applier cannot create the jellyfin account its unit would name";
assert lib.assertMsg ((vmtestConfig.systemd.services.jellyfin.serviceConfig.PrivateUsers or null) != true)
  "vmtest-wiring: jellyfin.service sets PrivateUsers=true — it breaks root outright (jellyfin#7897), so the unit cannot start";
assert lib.assertMsg ((vmtestConfig.systemd.services.jellyfin.serviceConfig.NoNewPrivileges or null) != true)
  "vmtest-wiring: jellyfin.service sets NoNewPrivileges=true — it silently kills hardware acceleration (jellyfin#7887), so transcoding degrades with no error surfaced";
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

# ── forgejo assertions ────────────────────────────────────────
assert lib.assertMsg ((vmtestConfig.systemd.services.forgejo.serviceConfig.DynamicUser or false) == true)
  "vmtest-wiring: forgejo no longer uses DynamicUser — ADR-036 needs it, because the applier cannot create the forgejo account and Forgejo refuses root";
assert lib.assertMsg ((vmtestConfig.systemd.services.forgejo.serviceConfig.StateDirectory or "") == "forgejo")
  "vmtest-wiring: forgejo dropped StateDirectory — without systemd re-owning its state on start, DynamicUser's recycled UIDs could hand forgejo's repos to another unit (systemd.exec(5))";
assert lib.assertMsg (vmtestConfig.services.forgejo.settings.DEFAULT.RUN_USER == "forgejo")
  "vmtest-wiring: forgejo RUN_USER does not name the dynamic user — Forgejo refuses to start when RUN_USER != its uid's name";
assert lib.assertMsg forgejoCfg.enable
  "vmtest-wiring: forgejo is not enabled — the dashboard.nix extraction dropped the forgejo toggle";
assert lib.assertMsg (forgejoSettings.ROOT_URL or "" == "https://${baseDomain}${forgejoCfg.path}/" && forgejoSettings.HTTP_ADDR or "" == "127.0.0.1" && forgejoSettings.DISABLE_SSH or false)
  "vmtest-wiring: forgejo server settings diverged — ROOT_URL must be the clearnet plane origin + base path (OIDC callback origin) on a loopback HTTP bind, SSH disabled";
assert lib.assertMsg (vmtestConfig.services.forgejo.database.type == "sqlite3")
  "vmtest-wiring: forgejo is not on SQLite — the single-db-instance contract was dropped";
assert lib.assertMsg (forgejoDexClient != null)
  "vmtest-wiring: dex staticClients has no 'forgejo' entry — client registration was dropped";
assert lib.assertMsg (forgejoDexClient != null && builtins.elem "https://${baseDomain}${forgejoCfg.path}/user/oauth2/dex/callback" (forgejoDexClient.redirectURIs or []) && builtins.elem "http://${i2pPlaneHost}${forgejoCfg.path}/user/oauth2/dex/callback" (forgejoDexClient.redirectURIs or []))
  "vmtest-wiring: forgejo dex client redirect URIs (clearnet plane + I2P plane) mismatch — SSO callbacks would dead-end";
assert lib.assertMsg (forgejoBootstrap != null && builtins.elem "multi-user.target" (forgejoBootstrap.wantedBy or []))
  "vmtest-wiring: fortress-forgejo-oidc-bootstrap is missing or has no boot activation — the dex auth source would never be registered";
assert lib.assertMsg (forgejoBootstrap != null && builtins.elem "forgejo.service" (forgejoBootstrap.after or []) && builtins.elem "dex.service" (forgejoBootstrap.after or []))
  "vmtest-wiring: fortress-forgejo-oidc-bootstrap does not order after forgejo + dex — it could run against an un-migrated DB or a down dex";
assert lib.assertMsg (lib.hasInfix "redir https://${baseDomain}${forgejoCfg.path}{uri} 307" forgejoVhost)
  "vmtest-wiring: the forgejo clearnet hostname is no longer a 307 stub to ${baseDomain}${forgejoCfg.path} — the failover matrix row for forgejo is gone";
assert lib.assertMsg (forgejoI2pVhost != null && lib.hasInfix "redir http://${i2pPlaneHost}${forgejoCfg.path}{uri} 307" forgejoI2pVhost)
  "vmtest-wiring: the forgejo .i2p twin is missing or no longer a 307 stub to the I2P plane path — forgejo would dead-end on the I2P plane";
assert lib.assertMsg (lib.hasInfix ">Location \"^http://127" clearnetPlane && lib.hasInfix "\"https://${baseDomain}\"" clearnetPlane)
  "vmtest-wiring: the clearnet plane vhost lost the dex issuer Location rewrite — SSO login would redirect the browser to an unreachable loopback address";

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

# ── I2P rewrite seam assertions ───────────────────────────────
# The dex issuer is a loopback address and is never browser-
# reachable: every redirect to it must be rewritten per-path by
# Caddy. A silently-dropped rewrite is the seam that leaves the
# login button pointing at an unreachable address.
assert lib.assertMsg (dexIssuer != null && lib.hasPrefix "http://127.0.0.1:" dexIssuer)
  "vmtest-wiring: dex issuer is not a loopback address (got: ${toString dexIssuer}) — a public issuer makes multi-origin SSO structurally impossible";
assert lib.assertMsg (lib.hasInfix "redir https://${baseDomain}${jfPath}{uri} 307" jellyfinVhost)
  "vmtest-wiring: the jellyfin clearnet hostname is no longer a 307 stub to ${baseDomain}${jfPath} — the failover matrix row for jellyfin is gone";
assert lib.assertMsg (jellyfinI2pVhost != null && lib.hasInfix "bind 127.0.0.1" jellyfinI2pVhost && lib.hasInfix "redir http://${i2pPlaneHost}${jfPath}{uri} 307" jellyfinI2pVhost)
  "vmtest-wiring: the jellyfin .i2p twin is missing or no longer a 307 stub to the I2P plane path — jellyfin would dead-end on the I2P plane";
assert lib.assertMsg (lib.hasInfix ">Location \"^http://127" i2pPlane && lib.hasInfix "\"http://${i2pPlaneHost}\"" i2pPlane)
  "vmtest-wiring: the I2P plane vhost lost the dex issuer Location rewrite — SSO would redirect the browser to an unreachable loopback address";
assert lib.assertMsg (lib.hasInfix "^https://${baseEscaped}(/|$)" i2pPlane && lib.hasInfix "\"http://${i2pPlaneHost}\$1\"" i2pPlane)
  "vmtest-wiring: the I2P plane vhost lost the clearnet-callback swap — dex would redirect the browser to the clearnet callback, dead on the I2P path";
assert lib.assertMsg (lib.hasInfix "^https://${baseEscaped}(/|$)" lanPlane && lib.hasInfix "\"http://{http.request.host}\$1\"" lanPlane)
  "vmtest-wiring: the LAN plane vhost lost the clearnet-callback swap — a login would drag the LAN browser onto the clearnet origin mid-flow";
assert lib.assertMsg (jellyfinDexClient != null && builtins.elem "http://${i2pPlaneHost}${jfPath}/sso/OIDC/Callback/dex" (jellyfinDexClient.redirectURIs or []) && builtins.elem "https://${baseDomain}${jfPath}/sso/OIDC/Callback/dex" (jellyfinDexClient.redirectURIs or []))
  "vmtest-wiring: the jellyfin plane callbacks (clearnet + I2P) are not registered in dex staticClients — SSO callbacks would dead-end";

# ── LAN access plane assertions (ADR-028) ─────────────────────
assert lib.assertMsg (lanAddress == "10.0.2.15" && lanDnsEnabled)
  "vmtest-wiring: vmtest does not set fortress.network.lanAddress — the LAN DNS plane is not exercised by the suite";
assert lib.assertMsg everyDomainAnswered
  "vmtest-wiring: dnsmasq does not answer every enabled service domain with the LAN address (got: ${builtins.toJSON dnsmasqAddresses}) — the LAN DNS enumeration dropped a service";
assert lib.assertMsg (builtins.elem "/${baseDomain}/${lanAddress}" dnsmasqAddresses)
  "vmtest-wiring: dnsmasq does not answer ${baseDomain} with the LAN address — the shared path-routing origin would not resolve on the LAN";
assert lib.assertMsg canaryAnswered
  "vmtest-wiring: dnsmasq does not NXDOMAIN the Firefox DoH canary (use-application-dns.net) — secure-DNS browsers bypass the split-horizon";
assert lib.assertMsg (lib.hasInfix "--conf-file=/nix/store/" dnsExec && !(lib.hasInfix "/etc/" dnsExec))
  "vmtest-wiring: fortress-dns does not take its config from the store — the ADR-035 applier cannot write /etc on NixOS, so the LAN DNS layer would silently never start";
assert lib.assertMsg (dnsUnit.serviceConfig.DynamicUser == true)
  "vmtest-wiring: fortress-dns does not run under DynamicUser — it would need an OS account the applier cannot create, so the unit dies on any host whose /etc/passwd the OS owns";
assert lib.assertMsg everyVhostBindsWildcard
  "vmtest-wiring: an enabled vhost does not bind the wildcard — a tailnet or LAN ingress would hit a closed port (correct DNS, dead ingress)";
assert lib.assertMsg (lanDashboardVhost != null)
  "vmtest-wiring: the LAN plane catch-all is missing — typing the box's LAN IP (or machine hostname) would 404 instead of serving the config homepage";
assert lib.assertMsg (lanDashboardVhost != null && lib.hasInfix "bind 0.0.0.0 ::" lanDashboardVhost.extraConfig)
  "vmtest-wiring: the LAN plane catch-all does not bind the wildcard — the homepage and every /<path> row would be unreachable on the LAN";

# ── HTTPS scoping assertions (2026-10-08) ─────────────────────
# HTTPS is scoped to the clearnet hostnames. Caddy's blanket
# `auto_https` redirect 308s every host on :80 to a certless HTTPS
# origin — the amon-sul hostname failure (2026-10-08). It is
# disabled; each clearnet hostname gets an explicit redirect; the LAN
# plane is a plain-HTTP catch-all. A regression silently breaks the
# machine hostname or resurrects the blanket redirect.
assert lib.assertMsg (lib.hasInfix "auto_https disable_redirects" caddyGlobalConfig)
  "vmtest-wiring: services.caddy.globalConfig does not disable the blanket auto_https redirect — every non-clearnet host on :80 would 308 to a certless HTTPS origin";
assert lib.assertMsg (builtins.all (h: let v = clearnetRedirectVhost h; in
    v != null && lib.hasInfix "redir https://${h}{uri} 308" v.extraConfig)
    (lib.unique ([baseDomain] ++ enabledDomains)))
  "vmtest-wiring: a clearnet hostname lost its explicit http->https redirect — it would serve the LAN plane over plain HTTP instead of redirecting";

# ── path-routing matrix assertions (ADR-034) ──────────────────
# The uniform entry point contract: every enabled service answers at
# `/<path>` on EVERY plane origin (proxy if path-routed, 307 if
# subdomain-routed), and the non-canonical hostname shape307s to the
# canonical. A dropped row or a lost redirect silently removes a
# service from one plane with no error anywhere.
assert lib.assertMsg (clearnetPlane != "" && lanPlane != "" && i2pPlane != "")
  "vmtest-wiring: a plane origin vhost is missing (clearnet/lan/i2p) — services would be unreachable at that plane's /<path> entry points";
assert lib.assertMsg (builtins.all (name: let s = routableEnabled.${name}; in
    rowIn clearnetPlane name s && rowIn lanPlane name s && rowIn i2pPlane name s)
    (lib.attrNames routableEnabled))
  "vmtest-wiring: an enabled service lost its /<path> row on a plane origin — its uniform entry point is gone";
assert lib.assertMsg (builtins.all (name: let s = routableEnabled.${name}; in
    !s.public || s.routing != "path" || (
      lib.hasInfix "reverse_proxy 127.0.0.1:${toString s.port}" clearnetPlane
      && lib.hasInfix "; Path=${s.path}" clearnetPlane))
    pathRoutedNames)
  "vmtest-wiring: a public path-routed service's plane row lost its proxy or its Set-Cookie Path=/<path> scope — apps sharing an origin would collide";
assert lib.assertMsg (lib.hasInfix "uri strip_prefix ${forgejoCfg.path}" clearnetPlane && lib.hasInfix "uri strip_prefix ${forgejoCfg.path}" lanPlane)
  "vmtest-wiring: a forgejo plane row lost its prefix strip — ROOT_URL is URL-generation only (forgejo serves at its root), so /git requests would 404";
assert lib.assertMsg (lib.hasInfix "redir https://${seerrCfg.domain}{uri} 307" clearnetPlane && lib.hasInfix "redir https://${seerrCfg.domain}/ 307" clearnetPlane)
  "vmtest-wiring: the clearnet plane's seerr row no longer307s to seerr's canonical hostname — the failover entry is gone";
assert lib.assertMsg (lib.hasInfix "redir http://${lanAddress}:${toString seerrCfg.port}{uri} 307" lanPlane)
  "vmtest-wiring: the LAN plane's seerr row no longer307s to its port-site — the bare-IP failover for the media front door is gone";
assert lib.assertMsg (lib.hasInfix "redir https://${cryptpadCfg.domain}{uri} 307" lanPlane)
  "vmtest-wiring: the LAN plane's cryptpad row no longer307s to its hostname — originLocked apps must fail over to their origin, not a second one";
assert lib.assertMsg (seerrPortSite != null && lib.hasInfix "bind ${lanAddress}" seerrPortSite && lib.hasInfix "reverse_proxy 127.0.0.1:${toString seerrCfg.port}" seerrPortSite)
  "vmtest-wiring: the seerr LAN port-site is missing or does not bind the LAN address and proxy the loopback app — the DNS-free seerr failover would 404";
assert lib.assertMsg (cryptpadPortSite == null)
  "vmtest-wiring: cryptpad got a LAN port-site despite originLocked — a second origin breaks CryptPad's safe/unsafe origin model";
assert lib.assertMsg (lanDashboardVhost != null && lib.hasInfix "reverse_proxy ${dashboardAddr}" lanDashboardVhost.extraConfig)
  "vmtest-wiring: the LAN plane catch-all does not reverse-proxy the client dashboard (${dashboardAddr}) — the homepage would 502";
assert lib.assertMsg (lanDashboardVhost != null && !lib.hasInfix "tls " lanDashboardVhost.extraConfig)
  "vmtest-wiring: the LAN plane catch-all emits a tls directive — HTTPS on a private IP is a browser warning, and the plain-HTTP homepage must not redirect to it";

# ── dashboard port-collision assertions ───────────────────────
assert lib.assertMsg (!dashboardDefaultCollides)
  "vmtest-wiring: the dashboard's default bind port collides with an enabled catalog service port — fortress-client and the service both bind loopback and one fails at boot (the cryptpad :3000 landmine)";
assert lib.assertMsg forcedCollisionFires
  "vmtest-wiring: the dashboard/service port-collision assertion never fires on a forced collision — the tripwire in client.nix is dead";

# ── claim-flow boot tripwire assertions ───────────────────────
assert lib.assertMsg clientEnabled
  "vmtest-wiring: services.fortress-client is not enabled in the vmtest composition — the claimable-boot bootstrap check has nothing to check";
assert lib.assertMsg claimableConfig
  "vmtest-wiring: vmtest's fortress-client.json is not the claimable shape (no {tunnel_ip} forward) — a boot-dead-end regression would not fire";
{
  vmtest-wiring = pkgs.runCommand "fortress-vmtest-wiring" {} ''
    cat > $out <<EOF
    fortress vmtest-wiring: PASS
      jellyfin: OIDC wired (plugins + branding), jellarr boot-activated
      forgejo: OIDC wired (dex client clearnet+i2p, auth-source bootstrap boot-activated)
      cryptpad: OIDC wired (SSO enabled + enforced, dex client registered, secret oneshot boot-activated, CRYPTPAD_CONFIG env set, SSO plugin bundled in package)
      ingress: caddy.service orders after fortress-client.service (ACME over the tunnel)
      path-routing matrix (ADR-034): one site per plane (LAN plane is a :80 catch-all), every service at /<path> on each, failover307s both directions, cookie Path scoping, per-plane dex issuer rewrite + I2P callback swap, seerr LAN port-site (cryptpad originLocked)
      I2P seam: loopback dex issuer, .i2p callback registered
      HTTPS scoping: blanket auto_https redirect disabled, every clearnet hostname redirects http->https, LAN plane serves plain HTTP for any host
      LAN DNS: dnsmasq answers every enabled service domain — and ${baseDomain} — with ${lanAddress}, DoH canary NXDOMAINs, every vhost binds the wildcard
      LAN plane: :80 catch-all reverse-proxies ${dashboardAddr} (DNS-free config homepage on the IP or machine hostname)
      dashboard port: default bind collides with no enabled service port; the collision assertion fires on a forced collision
      claim flow: fortress-client enabled in the claimable shape ({tunnel_ip} forwards) — the box boots its dashboard to be claimed
    EOF
  '';
}
