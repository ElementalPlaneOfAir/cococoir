// SPDX-License-Identifier: AGPL-3.0-or-later
//! `fortress-client` entry point — the customer box's single process.
//!
//! Runs the L4 forwarder (receiving traffic from the edge) and the
//! embedded config dashboard as concurrent tasks on one shared
//! shutdown signal. `fortress-edge` has its own control-plane main in
//! the `fortress-controlplane` crate, so this module is client-only.
//!
//! Flow: parse flags, init logger, read the JSON config, build the
//! forwarder, open the dashboard db + config path + auth mode, start
//! the health server and the dashboard server, then block on the
//! forwarder until SIGINT/SIGTERM. All three stop on one signal.

use std::sync::Arc;

use serde::Deserialize;
use tokio::sync::watch;
use tracing::span;
use tracing::{error, info};

use crate::dashboard;
use crate::pairing::{
    self, device_token_path, persisted_tunnel_state, substitute_tunnel_ip, tunnel_state_path,
    EnrollError, HttpEdgeClient, InviteConfig,
};
use crate::tunnel::{self, TunnelConfig};
use fortress_core::forwarder::{Config, Forward, Forwarder};
use fortress_core::health::{HealthServer, StatusFunc};
use fortress_core::logger;

/// The on-disk config file shape. Matches the Go binaries'
/// `configFile` struct; `deny_unknown_fields` rejects a typo'd key
/// at startup instead of silently dropping it.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    /// Defaults to no forwards: a box that serves only its dashboard has
    /// nothing to forward, and requiring the key forced every dashboard-
    /// only config to write `"forwards": []` or crash-loop on parse.
    #[serde(default)]
    forwards: Vec<Forward>,
    /// Optional client-owned tunnel: if present, the client generates +
    /// persists its own WG keypair, brings wg0 up, then the forwarder
    /// binds the tunnel IP.
    #[serde(default)]
    tunnel: Option<TunnelConfig>,
    /// Optional invite enrollment: the box dials the owner's invite
    /// URL, polls until approved, then persists the tunnel state. A
    /// static `tunnel` AND an `invite` together are a config error —
    /// a box is either Nix-wired or self-enrolled, never both.
    #[serde(default)]
    invite: Option<InviteConfig>,
}

/// CLI flags, mirroring the Go `flag` defaults.
#[derive(Debug)]
struct Flags {
    config_path: String,
    log_format: logger::Format,
    health_addr: String,
    dashboard_addr: String,
    catalog_path: Option<String>,
}

/// How the box boots: `Full` runs the forwarder (tunnel resolved or not
/// needed); `Claimable` has forwards waiting on a tunnel that does not
/// exist yet, so it serves the dashboard and waits to be claimed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootMode {
    Full,
    Claimable,
}

/// Decide the boot mode. A box whose forwards need `{tunnel_ip}` and
/// has no tunnel state cannot serve anything yet — it must survive to
/// show a claim surface instead of exiting (the dead end this mode
/// exists to kill).
pub fn boot_mode(tunnel: Option<&TunnelConfig>, forwards: &[Forward]) -> BootMode {
    let needs_tunnel = forwards.iter().any(pairing::forward_needs_tunnel);
    let mode = match (tunnel, needs_tunnel) {
        (None, true) => BootMode::Claimable,
        _ => BootMode::Full,
    };
    assert_eq!(
        mode == BootMode::Claimable,
        tunnel.is_none() && needs_tunnel,
        "claimable mode is exactly 'no tunnel + forwards that need one'"
    );
    mode
}

/// The forwards a `Full` boot will bind, or `None` when a config has
/// none. `Forwarder::new` rejects an empty list outright, and a box whose
/// only surface is the dashboard must not fail to boot over it — that is
/// exactly the crash-loop amon-sul hit (2026-10-09).
fn bindable_forwards(
    tunnel: Option<&TunnelConfig>,
    forwards: &[Forward],
) -> Option<Vec<Forward>> {
    if forwards.is_empty() {
        return None;
    }
    let resolved = match tunnel {
        Some(t) => substitute_tunnel_ip(forwards, t),
        None => forwards.to_vec(),
    };
    assert!(
        resolved.iter().all(|f| !pairing::forward_needs_tunnel(f)),
        "claimable mode gates every forward that still needs a tunnel"
    );
    Some(resolved)
}

/// The process-image restart a runtime claim triggers: after
/// `tunnel.json` exists, re-exec this very binary so the one boot path
/// resolves the persisted state and brings wg0 up. A seam so tests can
/// record the call instead of replacing the test process.
pub trait Restarter: Send + Sync {
    fn restart(&self);
}

/// The production [`Restarter`]: replace this process with the same
/// command line. systemd sees the same PID; dev runs behave the same.
pub struct ProcessRestarter;

impl Restarter for ProcessRestarter {
    fn restart(&self) {
        use std::os::unix::process::CommandExt;
        let argv: Vec<std::ffi::OsString> = std::env::args_os().collect();
        let Some((arg0, rest)) = argv.split_first() else {
            panic!("restart requires argv[0]");
        };
        let err = std::process::Command::new(arg0).args(rest).exec();
        panic!("re-exec of this process failed: {err}");
    }
}

/// The runtime claim action the dashboard's Remote access form drives:
/// enroll with the pasted invite URL, then re-exec into full mode. The
/// poll budget matches boot enrollment (5s x ~10k = 30 days of waiting
/// for the owner's approval). The edge is a parameter so tests script
/// it; the dashboard passes the HTTP client the URL derives.
pub async fn claim(
    edge: &dyn crate::pairing::EdgeClient,
    invite_url: &str,
    key_path: &std::path::Path,
    tunnel_state_path: &std::path::Path,
    device_token_path: &std::path::Path,
    restarter: &dyn Restarter,
) -> Result<(), EnrollError> {
    assert!(!invite_url.is_empty(), "claim needs an invite URL");
    let invite = InviteConfig::from_url(invite_url)?;
    let tunnel = pairing::enroll(
        edge,
        &invite,
        key_path,
        tunnel_state_path,
        device_token_path,
        std::time::Duration::from_secs(5),
        10_000,
    )
    .await?;
    info!(ip = %tunnel.ip, "claim: enrolled; restarting into full mode");
    restarter.restart();
    Ok(())
}

/// Shared entry point. `component` and `default_config` come from the
/// binary wrapper. Returns the process exit code.
pub async fn run(component: &str, default_config: &str) -> i32 {
    let flags = match parse_flags(component, default_config) {
        Ok(flags) => flags,
        Err(err) => {
            eprintln!("{err}");
            eprintln!("usage: {component} -config PATH -log-format text|json -health-addr ADDR -dashboard-addr ADDR [-catalog PATH]");
            return 1;
        }
    };
    logger::init(flags.log_format);
    let span = span!(tracing::Level::INFO, "fortress", component = component);
    let _entered = span.enter();

    let data = match std::fs::read(&flags.config_path) {
        Ok(data) => data,
        Err(err) => {
            error!(path = %flags.config_path, err = %err, "read config failed");
            return 1;
        }
    };
    let cfg: ConfigFile = match serde_json::from_slice(&data) {
        Ok(cfg) => cfg,
        Err(err) => {
            error!(path = %flags.config_path, err = %err, "parse config failed");
            return 1;
        }
    };
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    if cfg.tunnel.is_some() && cfg.invite.is_some() {
        error!("config: 'tunnel' and 'invite' are mutually exclusive — a box is Nix-wired OR self-enrolled");
        return 1;
    }

    // The dashboard is the control plane of the box: it edits the
    // machine's NixOS config. There is no unauthenticated mode, so a
    // box with no admin credential is a misconfiguration and must not
    // limp along half-running. Refuse to start before any side effects
    // (wg0, enrollment, forwarder binds) so the operator sees one clear
    // failure instead of a box that silently serves an open admin UI.
    let admin_config = match dashboard::auth::AdminConfig::from_env() {
        Some(config) => config,
        None => {
            error!(
                "FORTRESS_ADMIN_PASSWORD_HASH is not set — refusing to start; \
                 the dashboard would have no credential to gate with"
            );
            return 1;
        }
    };

    // Tunnel state resolution, in priority order:
    //   1. A persisted enrollment (tunnel.json) — the box already joined;
    //      no enrollment, no edge dependency at boot.
    //   2. An invite in the config — enroll now (begin → poll → persist).
    //   3. A legacy static tunnel in the Nix config — use as-is.
    // Fail-fast: a tunnel that cannot come up leaves the forwarder with
    // no addresses to bind, so remote access is dead.
    let tunnel_cfg: Option<TunnelConfig> = if let Some(persisted) =
        persisted_tunnel_state(&tunnel_state_path())
    {
        tracing::info!(
            ip = %persisted.tunnel.ip,
            iface = %persisted.tunnel.iface,
            hostname = %persisted.hostname,
            "tunnel: persisted enrollment"
        );
        Some(persisted.tunnel)
    } else if let Some(invite) = &cfg.invite {
        let key_path = tunnel::key_path();
        let edge = match HttpEdgeClient::new(&invite.invite_url) {
            Ok(edge) => edge,
            Err(err) => {
                error!(err = %err, "enroll: invite URL invalid");
                return 1;
            }
        };
        match pairing::enroll(
            &edge,
            invite,
            &key_path,
            &tunnel_state_path(),
            &device_token_path(),
            std::time::Duration::from_secs(5),
            10_000,
        )
        .await
        {
            Ok(tunnel_cfg) => {
                info!(ip = %tunnel_cfg.ip, iface = %tunnel_cfg.iface, "enrolled; tunnel state persisted");
                Some(tunnel_cfg)
            }
            Err(EnrollError::Denied) => {
                error!("enroll: the owner denied this machine's enrollment");
                return 1;
            }
            Err(err) => {
                error!(err = %err, "enroll failed");
                return 1;
            }
        }
    } else {
        cfg.tunnel.clone()
    };
    if let Some(tunnel_cfg) = &tunnel_cfg {
        let key_path = tunnel::key_path();
        match tunnel::ensure_keypair(&key_path) {
            Ok(pubkey) => {
                tracing::info!(iface = %tunnel_cfg.iface, public_key = %pubkey, "wg0 keypair ensured")
            }
            Err(err) => {
                error!(err = %err, "tunnel: keypair failed");
                return 1;
            }
        }
        if let Err(err) = tunnel::bring_up_wg0(tunnel_cfg, &key_path) {
            error!(err = %err, "tunnel: wg0 bring-up failed");
            return 1;
        }
        tracing::info!(iface = %tunnel_cfg.iface, ip = %tunnel_cfg.ip, "wg0 up");
    }

    // The forwards may reference the tunnel IP via the `{tunnel_ip}`
    // placeholder (enrollment assigns it at runtime). Substitution is a
    // no-op for configs with concrete addresses. A box whose forwards
    // need a tunnel that does not exist yet boots claimable: no
    // forwarder to bind, just the dashboard and health, so the owner
    // can claim it instead of watching it exit.
    let mode = boot_mode(tunnel_cfg.as_ref(), &cfg.forwards);
    let forwarder: Option<Arc<Forwarder>> = match mode {
        BootMode::Claimable => {
            info!("claimable: no tunnel yet — claim this box from its dashboard's Remote access panel");
            None
        }
        BootMode::Full => match bindable_forwards(tunnel_cfg.as_ref(), &cfg.forwards) {
            None => {
                info!("no forwards configured — running the dashboard only");
                None
            }
            Some(resolved) => match Forwarder::new(Config {
                forwards: resolved,
                component: component.to_string(),
                ..Config::default()
            }) {
                Ok(f) => Some(Arc::new(f)),
                Err(err) => {
                    error!(err = %err, "forwarder init failed");
                    return 1;
                }
            },
        },
    };

    // Dashboard: open the sqlite db, resolve the edited config path,
    // and start the server. Same rule as the missing admin hash above:
    // the dashboard runs authenticated or the process does not run. A
    // session store that cannot open would leave a login page that can
    // never persist a session — a box that "boots" but is unmanageable.
    let dashboard_addr = flags.dashboard_addr.clone();
    let claim_state = std::sync::Arc::new(std::sync::Mutex::new(dashboard::ClaimState::Unclaimed));
    let spawn_state = claim_state.clone();
    let claim_support = dashboard::ClaimSupport {
        state: claim_state,
        tunnel_state_path: tunnel_state_path(),
        spawn_claim: std::sync::Arc::new(move |url: String| {
            let state = spawn_state.clone();
            tokio::spawn(async move {
                let restarter = ProcessRestarter;
                let edge = match HttpEdgeClient::new(&url) {
                    Ok(edge) => edge,
                    Err(err) => {
                        *state.lock().unwrap() = dashboard::ClaimState::Failed {
                            message: err.to_string(),
                        };
                        return;
                    }
                };
                let result = claim(
                    &edge,
                    &url,
                    &tunnel::key_path(),
                    &tunnel_state_path(),
                    &device_token_path(),
                    &restarter,
                )
                .await;
                if let Err(err) = result {
                    *state.lock().unwrap() = dashboard::ClaimState::Failed {
                        message: match err {
                            EnrollError::Denied => {
                                "the owner denied this machine's enrollment".to_string()
                            }
                            other => other.to_string(),
                        },
                    };
                }
            });
        }),
    };
    // The service catalog, baked into the unit at eval time. A malformed
    // one is a build bug, so it stops the process rather than serving a
    // dashboard that silently lists nothing.
    let catalog = match &flags.catalog_path {
        Some(path) => match dashboard::catalog::Catalog::load(std::path::Path::new(path)) {
            Ok(catalog) => {
                tracing::info!(services = catalog.entries().len(), "service catalog loaded");
                catalog
            }
            Err(err) => {
                error!(err = %err, "service catalog failed to load");
                return 1;
            }
        },
        None => dashboard::catalog::Catalog::default(),
    };
    let prober = dashboard::catalog::Prober::new();

    let dashboard_task = match dashboard::Db::open().await {
        Ok(db) => {
            let config_path = dashboard::ConfigPath::resolve();
            tracing::info!(config = %config_path.as_path().display(), "dashboard config path");
            let auth = admin_config.clone();
            let dashboard_shutdown = shutdown_rx.clone();
            Some(tokio::spawn(async move {
                if let Err(err) = dashboard::serve(
                    db,
                    auth,
                    config_path,
                    &dashboard_addr,
                    dashboard_shutdown,
                    claim_support,
                    catalog,
                    prober,
                )
                .await
                {
                    error!(err = %err, "dashboard server exited with error");
                }
            }))
        }
        Err(err) => {
            error!(
                err = %err,
                "dashboard session store failed to open — refusing to start; \
                 without it the dashboard cannot authenticate anyone"
            );
            return 1;
        }
    };

    // Health server. The status closure reads the forwarder's stats
    // on every request (or reports claimable mode before the forwarder
    // exists). Same decoupling as Go: health never imports forwarder
    // types.
    let status_func: StatusFunc = match &forwarder {
        Some(f) => {
            let f = f.clone();
            Arc::new(move || serde_json::to_value(f.stats()).unwrap_or(serde_json::Value::Null))
        }
        None => Arc::new(|| serde_json::json!({ "status": "claimable" })),
    };
    let health = HealthServer::new(flags.health_addr.clone(), status_func);
    let health_shutdown = shutdown_rx.clone();
    let health_task = tokio::spawn(async move {
        if let Err(err) = health.run(health_shutdown).await {
            error!(err = %err, "health server exited with error");
        }
    });

    // Signal task: on SIGINT/SIGTERM, flip the shutdown channel.
    let signal_task = tokio::spawn(async move {
        wait_for_signal().await;
        info!("received signal, shutting down");
        let _ = shutdown_tx.send(true);
    });

    let code = match &forwarder {
        Some(f) => {
            let forwarder_run = f.clone();
            let forwarder_shutdown = shutdown_rx.clone();
            match forwarder_run.run(forwarder_shutdown).await {
                Ok(()) => 0,
                Err(err) => {
                    error!(err = %err, "forwarder exited with error");
                    1
                }
            }
        }
        None => {
            let mut claimable_shutdown = shutdown_rx.clone();
            let _ = claimable_shutdown.wait_for(|v| *v).await;
            0
        }
    };

    // The forwarder's run() only returns after its shutdown drain;
    // the dashboard (if running), health server, and signal task stop
    // on the same signal.
    let _ = health_task.await;
    if let Some(dashboard_task) = dashboard_task {
        let _ = dashboard_task.await;
    }
    let _ = signal_task.await;
    code
}

/// Waits for SIGINT or SIGTERM. Returns when either arrives.
async fn wait_for_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigint = signal(SignalKind::interrupt()).expect("install SIGINT handler");
        let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM handler");
        tokio::select! {
            _ = sigint.recv() => {}
            _ = sigterm.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

/// Parses `-config`, `-log-format`, `-health-addr`, and
/// `-dashboard-addr` from argv, applying the binary's defaults for
/// unset flags.
fn parse_flags(component: &str, default_config: &str) -> Result<Flags, String> {
    parse_flag_args(
        component,
        default_config,
        std::env::args().skip(1).collect(),
    )
}

/// Core of [`parse_flags`], split out so tests can pass an explicit
/// argument list instead of the process argv.
fn parse_flag_args(
    component: &str,
    default_config: &str,
    args: Vec<String>,
) -> Result<Flags, String> {
    let mut config_path = default_config.to_string();
    let mut log_format = "text".to_string();
    let mut health_addr = "127.0.0.1:9090".to_string();
    let mut dashboard_addr = "127.0.0.1:3210".to_string();
    // Optional: the Nix-rendered service catalog. Absent means an empty
    // catalog (the edge test runs the client with no services behind it),
    // never a missing dashboard.
    let mut catalog_path: Option<String> = None;

    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let value = args
            .next()
            .ok_or_else(|| format!("{component}: flag {arg} requires a value"))?;
        match arg.as_str() {
            "-config" => config_path = value,
            "-log-format" => log_format = value,
            "-health-addr" => health_addr = value,
            "-dashboard-addr" => dashboard_addr = value,
            "-catalog" => catalog_path = Some(value),
            other => return Err(format!("{component}: unknown flag {other}")),
        }
    }
    let log_format = logger::Format::parse(&log_format).map_err(|err| err.to_string())?;
    Ok(Flags {
        config_path,
        log_format,
        health_addr,
        dashboard_addr,
        catalog_path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parse_flags_defaults() {
        let flags = parse_flag_args("fortress-edge", "/etc/fortress-edge.json", args(&[])).unwrap();
        assert_eq!(flags.config_path, "/etc/fortress-edge.json");
        assert_eq!(flags.log_format, logger::Format::Text);
        assert_eq!(flags.health_addr, "127.0.0.1:9090");
        assert_eq!(flags.dashboard_addr, "127.0.0.1:3210");
    }

    #[test]
    fn parse_flags_custom() {
        let flags = parse_flag_args(
            "fortress-edge",
            "/etc/fortress-edge.json",
            args(&[
                "-config",
                "/tmp/x.json",
                "-log-format",
                "json",
                "-health-addr",
                "0.0.0.0:9090",
                "-dashboard-addr",
                "127.0.0.1:3999",
            ]),
        )
        .unwrap();
        assert_eq!(flags.config_path, "/tmp/x.json");
        assert_eq!(flags.log_format, logger::Format::Json);
        assert_eq!(flags.health_addr, "0.0.0.0:9090");
        assert_eq!(flags.dashboard_addr, "127.0.0.1:3999");
    }

    #[test]
    fn parse_flags_rejects_unknown_flag() {
        let err = parse_flag_args(
            "fortress-edge",
            "/etc/fortress-edge.json",
            args(&["-bogus", "1"]),
        )
        .unwrap_err();
        assert!(err.contains("unknown flag"));
    }

    #[test]
    fn parse_flags_rejects_unknown_format() {
        let err = parse_flag_args(
            "fortress-edge",
            "/etc/fortress-edge.json",
            args(&["-log-format", "yaml"]),
        )
        .unwrap_err();
        assert!(err.contains("unknown format"));
    }

    #[test]
    fn config_file_rejects_unknown_field() {
        let err = serde_json::from_str::<ConfigFile>(r#"{"forwards":[],"bogus":1}"#).unwrap_err();
        assert!(err.to_string().contains("unknown field"));
    }

    /// Tripwire for the amon-sul crash-loop (2026-10-09): `forwards` was
    /// a required key, so the dashboard-only default `settings = {}` was
    /// rejected at parse and fortress-client restart-looped 66 times with
    /// "missing field `forwards`" while `/` served nothing. A box with no
    /// forwards is a legitimate box — it runs the dashboard and nothing else.
    #[test]
    fn config_file_allows_a_dashboard_only_config() {
        let cfg: ConfigFile = serde_json::from_str("{}").expect("no forwards is a legal box");
        assert!(cfg.forwards.is_empty());
        assert!(cfg.tunnel.is_none());
        assert!(cfg.invite.is_none());
    }

    #[test]
    fn config_file_allows_an_explicit_empty_forwards() {
        let cfg: ConfigFile = serde_json::from_str(r#"{"forwards":[]}"#).unwrap();
        assert!(cfg.forwards.is_empty());
    }

    #[test]
    fn config_file_parses_invite_shape() {
        let cfg: ConfigFile = serde_json::from_str(
            r#"{"forwards":[{"listen_addr":"0.0.0.0:80","dest_addr":"{tunnel_ip}:80","proto":"tcp"}],"invite":{"invite_url":"https://proletariat.tech/i/polluted-move-cheetah-apple"}}"#,
        )
        .unwrap();
        let invite = cfg.invite.expect("invite present");
        assert_eq!(invite.iface, "wg0");
        assert_eq!(invite.prefix, 24);
        assert_eq!(invite.listen_port, 0);
        let (base, code) = invite.parse().unwrap();
        assert_eq!(base, "https://proletariat.tech");
        assert_eq!(code, "polluted-move-cheetah-apple");
        // A placeholder forward is legal in the file; validation that a
        // tunnel state exists happens at boot.
        assert!(cfg.forwards[0].dest_addr.contains("{tunnel_ip}"));
    }

    fn concrete_forward(dest: &str) -> Forward {
        use fortress_core::forwarder::Proto;
        Forward {
            listen_addr: "0.0.0.0:80".to_string(),
            proto: Proto::Tcp,
            dest_addr: dest.to_string(),
        }
    }

    fn resolved_tunnel() -> TunnelConfig {
        TunnelConfig {
            iface: "wg0".to_string(),
            ip: "10.10.0.7".to_string(),
            prefix: 24,
            edge_pubkey: "k".to_string(),
            edge_endpoint: "e:51820".to_string(),
            edge_allowed_ips: "10.10.0.0/24".to_string(),
            listen_port: 0,
        }
    }

    /// The reported dead end: a fresh box whose forwards need a tunnel
    /// used to exit before its dashboard served. It must boot claimable.
    /// The need can sit in EITHER address field — the self-enrolled
    /// shape listens ON the tunnel IP.
    #[test]
    fn boot_mode_is_claimable_only_without_a_tunnel_when_forwards_need_one() {
        use fortress_core::forwarder::Proto;
        let tunneled = concrete_forward("{tunnel_ip}:80");
        let concrete = concrete_forward("127.0.0.1:8080");
        let tunneled_listen = Forward {
            listen_addr: "{tunnel_ip}:443".to_string(),
            proto: Proto::Tcp,
            dest_addr: "127.0.0.1:443".to_string(),
        };
        let tunnel = resolved_tunnel();
        assert_eq!(boot_mode(None, &[tunneled.clone()]), BootMode::Claimable);
        assert_eq!(boot_mode(None, &[tunneled_listen]), BootMode::Claimable);
        assert_eq!(boot_mode(Some(&tunnel), &[tunneled]), BootMode::Full);
        assert_eq!(boot_mode(None, &[concrete]), BootMode::Full);
        assert_eq!(boot_mode(None, &[]), BootMode::Full);
    }

    /// The whole shape of a dashboard-only box, in one place. Both
    /// amon-sul crash-loops (2026-10-09) lived in this path — the config
    /// the Nix default produces failed to parse, then failed to build a
    /// forwarder — and nothing exercised it: `nix flake check` never runs
    /// Rust, and the vmtest fixture sets `settings.forwards` explicitly.
    /// If this test fails, a box that only serves its dashboard cannot boot.
    #[test]
    fn a_dashboard_only_config_needs_nothing_but_the_dashboard() {
        let cfg: ConfigFile = serde_json::from_str("{}").expect("the empty config parses");
        assert!(cfg.forwards.is_empty());
        assert!(cfg.tunnel.is_none());
        assert!(cfg.invite.is_none());
        assert_eq!(boot_mode(None, &cfg.forwards), BootMode::Full);
        assert!(bindable_forwards(None, &cfg.forwards).is_none());
    }

    /// Tripwire for the amon-sul crash-loop (2026-10-09): a dashboard-only
    /// config reached `Forwarder::new` with zero forwards, which rejects an
    /// empty list outright, and fortress-client restart-looped with
    /// "no forwards in config" while `/` served nothing. A box with nothing
    /// to forward runs no forwarder — it runs the dashboard.
    #[test]
    fn bindable_forwards_is_none_for_a_dashboard_only_config() {
        assert!(bindable_forwards(None, &[]).is_none());
        assert!(bindable_forwards(Some(&resolved_tunnel()), &[]).is_none());
    }

    #[test]
    fn bindable_forwards_resolves_placeholders_and_keeps_concrete() {
        let tunnel = resolved_tunnel();
        let resolved =
            bindable_forwards(Some(&tunnel), &[concrete_forward("{tunnel_ip}:80")])
                .expect("a tunneled forward binds once the tunnel exists");
        assert_eq!(resolved[0].dest_addr, "10.10.0.7:80");
        let concrete = bindable_forwards(None, &[concrete_forward("127.0.0.1:8080")])
            .expect("a concrete forward binds with no tunnel");
        assert_eq!(concrete[0].dest_addr, "127.0.0.1:8080");
    }

    struct RecordingRestarter {
        restarted: std::sync::Mutex<bool>,
    }

    impl Restarter for RecordingRestarter {
        fn restart(&self) {
            *self.restarted.lock().unwrap() = true;
        }
    }

    #[tokio::test]
    async fn claim_enrolls_persists_and_restarts_into_full_mode() {
        use crate::pairing::mocks::{approved, mock_edge_info, waiting, MockEdge};
        let mut edge = MockEdge::new(mock_edge_info());
        edge.script(vec![waiting(), approved()]);
        let restarter = RecordingRestarter {
            restarted: std::sync::Mutex::new(false),
        };
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("tunnel.json");
        claim(
            &edge,
            "https://proletariat.tech/i/polluted-move-cheetah-apple",
            &dir.path().join("wg-private.key"),
            &state_path,
            &dir.path().join("device-token"),
            &restarter,
        )
        .await
        .expect("claim");
        assert!(
            *restarter.restarted.lock().unwrap(),
            "a successful claim re-execs so the boot path brings wg0 up"
        );
        assert!(
            state_path.exists(),
            "the enrollment state persisted BEFORE the restart"
        );
    }

    #[tokio::test]
    async fn claim_denied_leaves_the_box_claimable() {
        use crate::pairing::mocks::{mock_edge_info, waiting, MockEdge};
        let mut edge = MockEdge::new(mock_edge_info());
        edge.script(vec![waiting(), crate::pairing::PollOutcome {
            status: "denied".to_string(),
            wg_ip: None,
            hostname: None,
            device_token: None,
        }]);
        let restarter = RecordingRestarter {
            restarted: std::sync::Mutex::new(false),
        };
        let dir = tempfile::tempdir().unwrap();
        let result = claim(
            &edge,
            "https://proletariat.tech/i/polluted-move-cheetah-apple",
            &dir.path().join("wg-private.key"),
            &dir.path().join("tunnel.json"),
            &dir.path().join("device-token"),
            &restarter,
        )
        .await;
        assert!(matches!(result, Err(EnrollError::Denied)));
        assert!(
            !*restarter.restarted.lock().unwrap(),
            "a denied claim must not restart"
        );
    }
}
