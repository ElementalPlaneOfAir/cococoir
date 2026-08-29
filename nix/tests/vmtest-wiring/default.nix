# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir vmtest-wiring check.
#
# L1: pure option-tree evaluation against the *actual* vmtest
# nixosConfiguration. No VM, no QEMU. Catches the regression
# class where an OIDC integration silently vanishes from the
# rendered config — e.g. a lib.mkForce discarding the
# integration's definitions, or missing boot activation.
#
# Why evaluate vmtest instead of a synthetic config: the bug
# this guards against lived in the composition of vmtest.nix
# with the cococoir modules, not in any single module. Only
# the real composition is a faithful tripwire.
{pkgs, vmtestConfig}:
let
  lib = pkgs.lib;

  # ── dashboard.nix extraction ─────────────────────────────────
  # The six service enables live in nixosConfigurations/dashboard.nix
  # (the customer-edited file). A silent drop of one during a refactor
  # would disable a service with no trace — assert they all render.
  dashboardServices = ["jellyfin" "cryptpad" "radarr" "sonarr" "lidarr" "prowlarr"];
  dashboardServiceEnabled = name:
    vmtestConfig.cococoir.services.${name}.enable or false;

  # ── jellyfin OIDC ────────────────────────────────────────────
  jellarrCfg = vmtestConfig.services.jellarr;
  plugins = jellarrCfg.config.plugins or null;
  branding = jellarrCfg.config.branding or null;
  folderNames = map (f: f.name) jellarrCfg.config.library.virtualFolders;

  # ── cryptpad OIDC ───────────────────────────────────────────
  cpSettings = vmtestConfig.services.cryptpad.settings;
  cpSso = cpSettings.sso or {};
  cpSsoProviders = cpSso.list or [];
  dexProvider = lib.findFirst (p: p.name == "dex") null cpSsoProviders;
  dexStaticClients = vmtestConfig.services.dex.settings.staticClients or [];
  cryptpadDexClient = lib.findFirst (c: c.id == "cryptpad") null dexStaticClients;
  cryptpadSecretSvc = vmtestConfig.systemd.services.cococoir-cryptpad-oidc-secret;
  cryptpadSvcEnv = vmtestConfig.systemd.services.cryptpad.serviceConfig.Environment or [];
  hasCryptpadConfigEnv = lib.any (e: lib.hasPrefix "CRYPTPAD_CONFIG=" e) cryptpadSvcEnv;
  hasCryptpadSSOConfigEnv = lib.any (e: lib.hasPrefix "CRYPTPAD_SSO_CONFIG=" e) cryptpadSvcEnv;
  cryptpadPkg = vmtestConfig.services.cryptpad.package;
  cryptpadPkgHasSSO = lib.strings.hasInfix "-with-sso" (cryptpadPkg.name or "");

  # ── ingress / ACME ordering ──────────────────────────────────
  # Caddy terminates ACME for every customer domain and those
  # challenges traverse the tunnel. If caddy.service doesn't order
  # after the client, a fresh boot races the tunnel and ACME backoff
  # leaves domains certless (auth/cryptpad incident, 2026-08-28).
  caddyOrdersAfterClient = builtins.elem "cococoir-client.service"
    (vmtestConfig.systemd.services.caddy.after or []);
in
# ── dashboard.nix assertions ──────────────────────────────────
# Every service declared in the customer-edited dashboard.nix must
# render enabled in the real composition.
assert lib.assertMsg (builtins.all dashboardServiceEnabled dashboardServices)
  "vmtest-wiring: a service enable from nixosConfigurations/dashboard.nix was dropped from the rendered config — the dashboard.nix extraction is broken";
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
assert lib.assertMsg (cryptpadDexClient != null && builtins.elem "https://${vmtestConfig.cococoir.services.cryptpad.domain}/ssoauth" (cryptpadDexClient.redirectURIs or []))
  "vmtest-wiring: cryptpad dex client redirect URI mismatch";
assert lib.assertMsg (cryptpadSecretSvc.wantedBy != null && builtins.elem "multi-user.target" cryptpadSecretSvc.wantedBy)
  "vmtest-wiring: cococoir-cryptpad-oidc-secret has no boot activation";
assert lib.assertMsg hasCryptpadConfigEnv
  "vmtest-wiring: cryptpad.service has no CRYPTPAD_CONFIG env var — the oidc config is not wired";
assert lib.assertMsg hasCryptpadSSOConfigEnv
  "vmtest-wiring: cryptpad.service has no CRYPTPAD_SSO_CONFIG env var — the SSO plugin config is not wired";
assert lib.assertMsg cryptpadPkgHasSSO
  "vmtest-wiring: cryptpad package is the vanilla nixpkgs cryptpad (no -with-sso suffix) — the SSO plugin override was dropped";

# ── ingress ordering assertion ────────────────────────────────
assert lib.assertMsg caddyOrdersAfterClient
  "vmtest-wiring: caddy.service does not order after cococoir-client.service — fresh boots race the tunnel and ACME backoff leaves customer domains certless";
{
  vmtest-wiring = pkgs.runCommand "cococoir-vmtest-wiring" {} ''
    cat > $out <<EOF
    cococoir vmtest-wiring: PASS
      jellyfin: OIDC wired (plugins + branding), jellarr boot-activated
      cryptpad: OIDC wired (SSO enabled + enforced, dex client registered, secret oneshot boot-activated, CRYPTPAD_CONFIG env set, SSO plugin bundled in package)
      ingress: caddy.service orders after cococoir-client.service (ACME over the tunnel)
    EOF
  '';
}
