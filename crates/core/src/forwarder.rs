// SPDX-License-Identifier: AGPL-3.0-or-later
//! Shared L4 TCP/UDP forwarder used by both `cococoir-edge` (VPS)
//! and `cococoir-client` (customer box). The two binaries are thin
//! wrappers around this module: they parse a JSON config of
//! `{forwards: [{listen_addr, proto, dest_addr}, ...]}` and hand
//! the slice to a `Forwarder`.
//!
//! Design: `new()` validates the config; `run()` binds all
//! listeners, runs until the shutdown signal fires, then performs
//! graceful shutdown (close listeners, wait for in-flight conns to
//! drain with a timeout).
//!
//! Port notes vs the Go original (`internal/forwarder`):
//! - `Proto` is a Rust enum: invalid protos are unrepresentable and
//!   rejected by serde at config parse, not by a runtime check.
//! - Config has explicit `Default` values instead of Go's
//!   zero-value-sentinel magic.
//! - Config `Forward` uses `deny_unknown_fields`: a typo'd config
//!   key fails at startup instead of being silently dropped.

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::watch;
use tokio_util::task::TaskTracker;

use crate::retry::{retry_bind_tcp, retry_bind_tcp_freebind, retry_bind_udp, BindError};
use crate::tcp::serve_tcp;
use crate::udp::serve_udp;

/// Protocol of a [`Forward`]. Rust enum: invalid protos cannot be
/// constructed, and serde rejects `"proto": "sctp"` at config parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Proto {
    Tcp,
    Udp,
}

impl Proto {
    /// Wire string used in the JSON contract ("tcp" / "udp").
    pub fn as_str(&self) -> &'static str {
        match self {
            Proto::Tcp => "tcp",
            Proto::Udp => "udp",
        }
    }
}

/// One entry of the `forwards` list. The JSON shape is the contract
/// consumed by both binaries and by operator config files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Forward {
    #[serde(rename = "listen_addr")]
    pub listen_addr: String,
    pub proto: Proto,
    #[serde(rename = "dest_addr")]
    pub dest_addr: String,
}

/// Forwarder configuration. Built by the cmd entry points from the
/// JSON config file plus their own CLI defaults.
#[derive(Debug, Clone)]
pub struct Config {
    pub forwards: Vec<Forward>,
    pub shutdown_timeout: Duration,
    pub bind_timeout: Duration,
    pub udp_flow_idle: Duration,
    pub component: String,
    /// Interface holding the edge's routed IPv6 /64. Customer `/128`
    /// listeners must be added as local addresses here before they are
    /// reachable: `IPV6_FREEBIND` binds an unassigned in-subnet `/128`
    /// socket, but the kernel only delivers packets to an address it
    /// considers local. Without this, the `/128` is unreachable from the
    /// internet (silent — bind succeeds, traffic never arrives).
    pub ipv6_iface: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            forwards: Vec::new(),
            shutdown_timeout: Duration::from_secs(30),
            bind_timeout: Duration::from_secs(30),
            udp_flow_idle: Duration::from_secs(300),
            component: "cococoir".to_string(),
            ipv6_iface: None,
        }
    }
}

/// Config validation failure. `index` names which entry of the
/// `forwards` list failed, matching the Go `ConfigError`.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ConfigError {
    #[error("forwarder: no forwards in config")]
    EmptyForwards,
    #[error("forwarder: forwards[{index}]: {message}")]
    InvalidForward { index: usize, message: String },
}

/// Point-in-time snapshot of forwarder state, safe to consume from
/// any task. The JSON shape is the contract of the `/status`
/// endpoint (see `cococoir::health`).
#[derive(Debug, Clone, Serialize)]
pub struct Stats {
    pub component: String,
    #[serde(rename = "started_at")]
    pub started_at: DateTime<Utc>,
    #[serde(rename = "uptime_seconds")]
    pub uptime_seconds: f64,
    pub forwards: Vec<ForwardStat>,
    #[serde(rename = "tcp_connections")]
    pub tcp_connections: i64,
    #[serde(rename = "udp_flows")]
    pub udp_flows: i64,
}

/// Per-forward row in [`Stats`]. Either `bound` is true (the
/// listener is up) or `last_error` is non-empty (the bind failed).
#[derive(Debug, Clone, Serialize)]
pub struct ForwardStat {
    pub proto: Proto,
    #[serde(rename = "listen_addr")]
    pub listen_addr: String,
    #[serde(rename = "dest_addr")]
    pub dest_addr: String,
    pub bound: bool,
    #[serde(rename = "bound_at", skip_serializing_if = "Option::is_none")]
    pub bound_at: Option<DateTime<Utc>>,
    #[serde(rename = "last_error", skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

/// Inner mutable state shared between `run()`'s tasks and
/// `stats()`. Atomics for the counters (lock-free), one `RwLock`
/// for the per-forward map, one `RwLock` for the live listener
/// handles (added/removed by `add_forward`/`remove_forward`), and
/// the shutdown sender live forwards share.
#[derive(Debug)]
pub(crate) struct State {
    forwards: RwLock<HashMap<String, ForwardStat>>,
    handles: RwLock<HashMap<String, tokio::task::AbortHandle>>,
    shutdown_tx: watch::Sender<bool>,
    tcp_connections: AtomicI64,
    udp_flows: AtomicI64,
}

impl Default for State {
    fn default() -> Self {
        let (shutdown_tx, _) = watch::channel(false);
        Self {
            forwards: RwLock::new(HashMap::new()),
            handles: RwLock::new(HashMap::new()),
            shutdown_tx,
            tcp_connections: AtomicI64::new(0),
            udp_flows: AtomicI64::new(0),
        }
    }
}

impl State {
    pub(crate) fn inc_tcp_connections(&self) {
        self.tcp_connections.fetch_add(1, Ordering::SeqCst);
    }

    pub(crate) fn dec_tcp_connections(&self) {
        if self.tcp_connections.load(Ordering::SeqCst) > 0 {
            self.tcp_connections.fetch_sub(1, Ordering::SeqCst);
        }
    }

    pub(crate) fn inc_udp_flows(&self) {
        self.udp_flows.fetch_add(1, Ordering::SeqCst);
    }

    pub(crate) fn dec_udp_flows(&self) {
        if self.udp_flows.load(Ordering::SeqCst) > 0 {
            self.udp_flows.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// A live receiver for the forwarder's shutdown signal. Spawned
    /// serve tasks hold one of these so they keep running until
    /// shutdown (or are aborted by `remove_forward`).
    fn shutdown_rx(&self) -> watch::Receiver<bool> {
        self.shutdown_tx.subscribe()
    }

    /// Record a forward as bound, storing the address the socket is
    /// actually listening on (not the requested one — a `:0` listen
    /// only resolves to a real port once the kernel assigns it).
    fn record_bound(&self, fwd: &Forward, actual_listen_addr: String, at: DateTime<Utc>) {
        let mut forwards = self.forwards.write().unwrap();
        forwards.insert(
            forward_key(fwd),
            ForwardStat {
                proto: fwd.proto,
                listen_addr: actual_listen_addr,
                dest_addr: fwd.dest_addr.clone(),
                bound: true,
                bound_at: Some(at),
                last_error: None,
            },
        );
    }

    fn record_bind_error(&self, fwd: &Forward, err: &BindError) {
        let mut forwards = self.forwards.write().unwrap();
        forwards.insert(
            forward_key(fwd),
            ForwardStat {
                proto: fwd.proto,
                listen_addr: fwd.listen_addr.clone(),
                dest_addr: fwd.dest_addr.clone(),
                bound: false,
                bound_at: None,
                last_error: Some(err.to_string()),
            },
        );
    }

    fn snapshot(&self, component: String, started_at: DateTime<Utc>) -> Stats {
        let forwards = {
            let guard = self.forwards.read().unwrap();
            guard.values().cloned().collect()
        };
        Stats {
            component,
            started_at,
            uptime_seconds: (Utc::now() - started_at).num_milliseconds() as f64 / 1000.0,
            forwards,
            tcp_connections: self.tcp_connections.load(Ordering::SeqCst),
            udp_flows: self.udp_flows.load(Ordering::SeqCst),
        }
    }

    /// Register the live task handle for a forward key.
    fn insert_handle(&self, key: &str, handle: tokio::task::AbortHandle) {
        let mut handles = self.handles.write().unwrap();
        handles.insert(key.to_string(), handle);
    }

    /// Take and abort the live task for a forward key, if any.
    /// Returns whether a handle existed.
    fn abort_handle(&self, key: &str) -> bool {
        let handle = {
            let mut handles = self.handles.write().unwrap();
            handles.remove(key)
        };
        match handle {
            Some(h) => {
                h.abort();
                true
            }
            None => false,
        }
    }

    /// Whether a live task is registered for a forward key, without
    /// taking it.
    fn abort_handle_peek(&self, key: &str) -> bool {
        self.handles.read().unwrap().contains_key(key)
    }

    /// Number of forwards currently bound (for logs/status).
    fn forwards_len(&self) -> usize {
        self.forwards.read().unwrap().len()
    }
}

/// Fatal error from [`Forwarder::run`]. Binding a listener with
/// retry-with-backoff failed (either non-transient, timed out, or
/// cancelled by shutdown).
#[derive(Debug, Error)]
pub enum RunError {
    #[error("forwarder: start {proto} {addr}: {source}")]
    Bind {
        proto: &'static str,
        addr: String,
        #[source]
        source: BindError,
    },
}

#[derive(Debug)]
pub struct Forwarder {
    cfg: Config,
    state: Arc<State>,
    started_at: DateTime<Utc>,
}

/// Best-effort: make the IPv6 `/128` in `listen_addr` a local address on
/// `iface`. `IPV6_FREEBIND` binds an unassigned in-subnet `/128` socket,
/// but the kernel only delivers packets to an address it treats as local —
/// without this, the `/128` binds but is unreachable from the internet.
/// Idempotent: re-adding an already-present address reports "already
/// assigned", which we tolerate. Runs once per add; reconcile-on-boot
/// re-adds forwards so a reboot re-installs the addresses too.
fn ensure_ipv6_local(iface: &str, listen_addr: &str) {
    let Ok(sa) = listen_addr.parse::<std::net::SocketAddr>() else {
        return;
    };
    if !sa.is_ipv6() {
        return;
    }
    let ip = sa.ip();
    let out = std::process::Command::new("ip")
        .args(["-6", "addr", "add", &format!("{ip}/128"), "dev", iface])
        .output();
    if let Ok(out) = out {
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            if !err.to_lowercase().contains("already assigned") {
                tracing::warn!(iface, ip = %ip, err = %err.trim(), "ipv6 addr add failed");
            }
        }
    }
}

impl Forwarder {
    /// Validates `cfg` and returns a ready `Forwarder`. Callers then
    /// drive it with `run()`.
    pub fn new(cfg: Config) -> Result<Self, ConfigError> {
        if cfg.forwards.is_empty() {
            return Err(ConfigError::EmptyForwards);
        }
        Self::new_live(cfg)
    }

    /// A forwarder that starts with zero forwards, accepting new ones
    /// only via `add_forward`. This is the edge's shape: customers are
    /// added at runtime by the control plane, so an empty initial set
    /// is valid. For the client (static config), use [`Forwarder::new`].
    pub fn new_live(cfg: Config) -> Result<Self, ConfigError> {
        for (index, fwd) in cfg.forwards.iter().enumerate() {
            if fwd.listen_addr.is_empty() {
                return Err(ConfigError::InvalidForward {
                    index,
                    message: "empty listen_addr".to_string(),
                });
            }
            if fwd.dest_addr.is_empty() {
                return Err(ConfigError::InvalidForward {
                    index,
                    message: "empty dest_addr".to_string(),
                });
            }
        }
        Ok(Self {
            cfg,
            state: Arc::new(State::default()),
            started_at: Utc::now(),
        })
    }

    pub fn component(&self) -> &str {
        &self.cfg.component
    }

    /// Binds all listeners (with retry-with-backoff), then runs until
    /// the shutdown signal fires. On shutdown: stop accepting, close
    /// the listeners, and wait up to `shutdown_timeout` for in-flight
    /// conns to drain.
    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) -> Result<(), RunError> {
        let tracker = TaskTracker::new();
        for fwd in &self.cfg.forwards {
            match fwd.proto {
                Proto::Tcp => {
                    let ln = retry_bind_tcp(&fwd.listen_addr, self.cfg.bind_timeout, shutdown.clone())
                        .await
                        .map_err(|source| {
                            self.state.record_bind_error(fwd, &source);
                            RunError::Bind {
                                proto: fwd.proto.as_str(),
                                addr: fwd.listen_addr.clone(),
                                source,
                            }
                        })?;
                    self.state.record_bound(fwd, ln.local_addr().unwrap().to_string(), Utc::now());
                    let state = self.state.clone();
                    let shutdown = shutdown.clone();
                    tracker.spawn(serve_tcp(
                        ln,
                        fwd.dest_addr.clone(),
                        state,
                        tracker.clone(),
                        shutdown,
                    ));
                }
                Proto::Udp => {
                    let sock = retry_bind_udp(&fwd.listen_addr, self.cfg.bind_timeout, shutdown.clone())
                        .await
                        .map_err(|source| {
                            self.state.record_bind_error(fwd, &source);
                            RunError::Bind {
                                proto: fwd.proto.as_str(),
                                addr: fwd.listen_addr.clone(),
                                source,
                            }
                        })?;
                    self.state.record_bound(fwd, sock.local_addr().unwrap().to_string(), Utc::now());
                    let state = self.state.clone();
                    let shutdown = shutdown.clone();
                    tracker.spawn(serve_udp(
                        Arc::new(sock),
                        fwd.dest_addr.clone(),
                        self.cfg.udp_flow_idle,
                        state,
                        tracker.clone(),
                        shutdown,
                    ));
                }
            }
        }
        tracing::info!(count = self.cfg.forwards.len(), "forwarder running");
        let _ = shutdown.wait_for(|v| *v).await;
        // Propagate to live forwards (added via add_forward) so they
        // stop too; their serve tasks hold a receiver on this channel.
        let _ = self.state.shutdown_tx.send(true);
        tracing::info!(drain_timeout = ?self.cfg.shutdown_timeout, "forwarder shutting down");
        tracker.close();
        match tokio::time::timeout(self.cfg.shutdown_timeout, tracker.wait()).await {
            Ok(()) => tracing::info!("forwarder drained"),
            Err(_) => tracing::error!(
                drain_timeout = ?self.cfg.shutdown_timeout,
                "forwarder drain timed out"
            ),
        }
        Ok(())
    }

    /// Point-in-time snapshot of forwarder state. Safe to call from
    /// any task, including HTTP handlers. The returned struct is a
    /// fresh copy; mutating it does not affect the forwarder.
    pub fn stats(&self) -> Stats {
        self.state.snapshot(self.cfg.component.clone(), self.started_at)
    }

    /// Add a forward at runtime: bind the listener (with retry and
    /// `IPV6_FREEBIND` for IPv6 addresses) and start serving it,
    /// without touching any existing listener. This is the live path
    /// the control plane uses at customer signup. Re-adding a forward
    /// that already exists is a no-op (returns `Ok`).
    ///
    /// Errors only when the bind itself fails (non-transient or
    /// timed-out); existing forwards are unaffected.
    pub async fn add_forward(&self, fwd: &Forward) -> Result<(), RunError> {
        let key = forward_key(fwd);
        if self.state.abort_handle_peek(&key) {
            // Already running; nothing to do.
            return Ok(());
        }
        if let Some(iface) = &self.cfg.ipv6_iface {
            ensure_ipv6_local(iface, &fwd.listen_addr);
        }
        let tracker = TaskTracker::new();
        match fwd.proto {
            Proto::Tcp => {
                let ln = retry_bind_tcp_freebind(
                    &fwd.listen_addr,
                    self.cfg.bind_timeout,
                    self.shutdown_rx(),
                )
                .await
                .map_err(|source| {
                    self.state.record_bind_error(fwd, &source);
                    RunError::Bind {
                        proto: fwd.proto.as_str(),
                        addr: fwd.listen_addr.clone(),
                        source,
                    }
                })?;
                self.state.record_bound(fwd, ln.local_addr().unwrap().to_string(), Utc::now());
                let state = self.state.clone();
                let shutdown = self.shutdown_rx();
                let handle = tokio::spawn(serve_tcp(
                    ln,
                    fwd.dest_addr.clone(),
                    state,
                    tracker,
                    shutdown,
                ));
                self.state.insert_handle(&key, handle.abort_handle());
            }
            Proto::Udp => {
                let sock = retry_bind_udp(
                    &fwd.listen_addr,
                    self.cfg.bind_timeout,
                    self.shutdown_rx(),
                )
                .await
                .map_err(|source| {
                    self.state.record_bind_error(fwd, &source);
                    RunError::Bind {
                        proto: fwd.proto.as_str(),
                        addr: fwd.listen_addr.clone(),
                        source,
                    }
                })?;
                self.state.record_bound(fwd, sock.local_addr().unwrap().to_string(), Utc::now());
                let state = self.state.clone();
                let shutdown = self.shutdown_rx();
                let handle = tokio::spawn(serve_udp(
                    Arc::new(sock),
                    fwd.dest_addr.clone(),
                    self.cfg.udp_flow_idle,
                    state,
                    tracker,
                    shutdown,
                ));
                self.state.insert_handle(&key, handle.abort_handle());
            }
        }
        tracing::info!(count = self.state.forwards_len(), "forwarder running");
        Ok(())
    }

    /// Remove a live forward: abort its serve task and drop its stats
    /// row. Returns whether a forward with that key existed. Existing
    /// forwards are unaffected.
    pub fn remove_forward(&self, fwd: &Forward) -> bool {
        let key = forward_key(fwd);
        let aborted = self.state.abort_handle(&key);
        if aborted {
            let mut forwards = self.state.forwards.write().unwrap();
            forwards.remove(&key);
        }
        aborted
    }

    /// A fresh shutdown receiver for spawned tasks. Live forwards
    /// (added via `add_forward`) keep serving until `run()`'s
    /// shutdown fires — at which point it also signals the internal
    /// channel so live forwards stop with the rest.
    fn shutdown_rx(&self) -> watch::Receiver<bool> {
        self.state.shutdown_rx()
    }
}

/// Map key for the per-forward stats row. Matches Go's
/// `proto://listen_addr`.
fn forward_key(fwd: &Forward) -> String {
    format!("{}://{}", fwd.proto.as_str(), fwd.listen_addr)
}

#[cfg(test)]
mod tests {
    #[test]
    fn ensure_ipv6_local_is_best_effort_no_panic() {
        // IPv4 listen: no-op (returns before invoking `ip`).
        ensure_ipv6_local("eth0", "127.0.0.1:80");
        // Invalid address: no-op.
        ensure_ipv6_local("eth0", "not-an-address");
        // IPv6: attempts `ip -6 addr add`; a non-root/offline CI runner
        // fails the command but the helper must tolerate it silently.
        ensure_ipv6_local("eth0", "[2a01:4f9:c014:2c44::3]:80");
    }
    use super::*;

    #[test]
    fn new_rejects_empty_forwards() {
        let err = Forwarder::new(Config::default()).unwrap_err();
        assert_eq!(err, ConfigError::EmptyForwards);
    }

    #[test]
    fn new_rejects_empty_listen_addr() {
        let err = Forwarder::new(Config {
            forwards: vec![Forward {
                listen_addr: "".to_string(),
                proto: Proto::Tcp,
                dest_addr: "127.0.0.1:1".to_string(),
            }],
            ..Config::default()
        })
        .unwrap_err();
        assert_eq!(
            err,
            ConfigError::InvalidForward {
                index: 0,
                message: "empty listen_addr".to_string()
            }
        );
    }

    #[test]
    fn new_rejects_empty_dest_addr() {
        let err = Forwarder::new(Config {
            forwards: vec![Forward {
                listen_addr: "127.0.0.1:1".to_string(),
                proto: Proto::Tcp,
                dest_addr: "".to_string(),
            }],
            ..Config::default()
        })
        .unwrap_err();
        assert_eq!(
            err,
            ConfigError::InvalidForward {
                index: 0,
                message: "empty dest_addr".to_string()
            }
        );
    }

    #[test]
    fn new_reports_index_of_failing_forward() {
        let err = Forwarder::new(Config {
            forwards: vec![
                Forward {
                    listen_addr: "127.0.0.1:1".to_string(),
                    proto: Proto::Tcp,
                    dest_addr: "127.0.0.1:2".to_string(),
                },
                Forward {
                    listen_addr: "".to_string(),
                    proto: Proto::Udp,
                    dest_addr: "127.0.0.1:2".to_string(),
                },
            ],
            ..Config::default()
        })
        .unwrap_err();
        assert_eq!(
            err,
            ConfigError::InvalidForward {
                index: 1,
                message: "empty listen_addr".to_string()
            }
        );
    }

    #[test]
    fn new_accepts_valid_config() {
        let f = Forwarder::new(Config {
            forwards: vec![Forward {
                listen_addr: "127.0.0.1:0".to_string(),
                proto: Proto::Tcp,
                dest_addr: "127.0.0.1:1".to_string(),
            }],
            component: "cococoir-edge".to_string(),
            ..Config::default()
        })
        .unwrap();
        assert_eq!(f.component(), "cococoir-edge");
    }

    #[test]
    fn default_component_is_cococoir() {
        let f = Forwarder::new(Config {
            forwards: vec![Forward {
                listen_addr: "127.0.0.1:0".to_string(),
                proto: Proto::Tcp,
                dest_addr: "127.0.0.1:1".to_string(),
            }],
            ..Config::default()
        })
        .unwrap();
        assert_eq!(f.component(), "cococoir");
    }

    #[test]
    fn forward_rejects_unknown_proto_at_parse() {
        let err = serde_json::from_str::<Forward>(
            r#"{"listen_addr":"127.0.0.1:0","proto":"sctp","dest_addr":"127.0.0.1:1"}"#,
        )
        .unwrap_err();
        assert!(err.to_string().contains("unknown variant"));
    }

    #[test]
    fn forward_rejects_unknown_field() {
        let err = serde_json::from_str::<Forward>(
            r#"{"listen_addr":"127.0.0.1:0","proto":"tcp","dest_addr":"127.0.0.1:1","nope":1}"#,
        )
        .unwrap_err();
        assert!(err.to_string().contains("unknown field"));
    }

    #[test]
    fn forward_parses_valid_json() {
        let f: Forward = serde_json::from_str(
            r#"{"listen_addr":"127.0.0.1:0","proto":"udp","dest_addr":"127.0.0.1:1"}"#,
        )
        .unwrap();
        assert_eq!(f.proto, Proto::Udp);
        assert_eq!(f.listen_addr, "127.0.0.1:0");
    }

    #[test]
    fn forward_key_is_proto_colon_slash_slash_listen() {
        let f = Forward {
            listen_addr: "1.2.3.4:80".to_string(),
            proto: Proto::Tcp,
            dest_addr: "10.0.0.2:80".to_string(),
        };
        assert_eq!(forward_key(&f), "tcp://1.2.3.4:80");
    }

    #[test]
    fn proto_serializes_lowercase() {
        assert_eq!(serde_json::to_string(&Proto::Tcp).unwrap(), "\"tcp\"");
        assert_eq!(serde_json::to_string(&Proto::Udp).unwrap(), "\"udp\"");
    }

    // ── integration tests: port of Go forwarder_test.go ──────────

    use std::net::SocketAddr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream, UdpSocket};
    use tokio::sync::watch;

    /// The port a running forward actually listens on, read back from
    /// the bound address stats record. Tests give the forwarder a `:0`
    /// listen address and read the kernel-assigned port here — a test
    /// never predicts or re-binds a port, so no process (sibling test
    /// or host) can race it.
    async fn bound_port(f: &Forwarder) -> u16 {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            let stats = f.stats();
            if let Some(s) = stats.forwards.iter().find(|s| s.bound) {
                return s.listen_addr.parse::<SocketAddr>().unwrap().port();
            }
            assert!(
                std::time::Instant::now() < deadline,
                "forward never bound: {:?}",
                f.stats()
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }

    async fn echo_tcp(ln: TcpListener) {
        loop {
            let Ok((mut conn, _)) = ln.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = vec![0u8; 65535];
                loop {
                    match conn.read(&mut buf).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => {
                            if conn.write_all(&buf[..n]).await.is_err() {
                                return;
                            }
                        }
                    }
                }
            });
        }
    }

    async fn echo_udp(s: Arc<UdpSocket>) {
        let mut buf = vec![0u8; 65535];
        loop {
            match s.recv_from(&mut buf).await {
                Ok((n, src)) => {
                    if s.send_to(&buf[..n], src).await.is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    }

    async fn round_trip_tcp(port: u16, msg: &[u8]) -> Vec<u8> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if let Ok(mut conn) = TcpStream::connect(("127.0.0.1", port)).await {
                conn.write_all(msg).await.unwrap();
                let mut buf = vec![0u8; msg.len()];
                conn.read_exact(&mut buf).await.unwrap();
                return buf;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "could not connect to forwarder on port {port}"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }

    async fn round_trip_tcp_v6(port: u16, msg: &[u8]) -> Vec<u8> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if let Ok(mut conn) = TcpStream::connect(("::1", port)).await {
                conn.write_all(msg).await.unwrap();
                let mut buf = vec![0u8; msg.len()];
                conn.read_exact(&mut buf).await.unwrap();
                return buf;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "could not connect to ipv6 forwarder on port {port}"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }

    async fn round_trip_udp(port: u16, msg: &[u8]) -> Vec<u8> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            let s = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            if s.connect(("127.0.0.1", port)).await.is_ok() && s.send(msg).await.is_ok() {
                let mut buf = vec![0u8; 65535];
                if let Ok(n) = tokio::time::timeout(
                    std::time::Duration::from_millis(500),
                    s.recv(&mut buf),
                )
                .await
                {
                    if let Ok(n) = n {
                        return buf[..n].to_vec();
                    }
                }
            }
            assert!(
                std::time::Instant::now() < deadline,
                "udp round-trip on port {port} timed out"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }

    /// Spawn a forwarder in the background; returns the forwarder, the
    /// shutdown sender, and the run task. Tests flip shutdown to stop it.
    fn spawn_forwarder(
        cfg: Config,
    ) -> (
        Arc<Forwarder>,
        watch::Sender<bool>,
        tokio::task::JoinHandle<Result<(), RunError>>,
    ) {
        let f = Arc::new(Forwarder::new(cfg).unwrap());
        let (tx, rx) = watch::channel(false);
        let handle = tokio::spawn({
            let f = f.clone();
            async move { f.run(rx).await }
        });
        (f, tx, handle)
    }

    fn forward(proto: Proto, listen_addr: &str, dest: &str) -> Forward {
        Forward {
            listen_addr: listen_addr.to_string(),
            proto,
            dest_addr: dest.to_string(),
        }
    }

    #[tokio::test]
    async fn run_tcp_forward() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        tokio::spawn(echo_tcp(upstream));

        let (f, tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(
                Proto::Tcp,
                "127.0.0.1:0",
                &format!("127.0.0.1:{upstream_port}"),
            )],
            ..Config::default()
        });
        let fwd_port = bound_port(&f).await;

        let got = round_trip_tcp(fwd_port, b"ping").await;
        assert_eq!(got, b"ping");

        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn run_tcp_forward_ipv6_listen() {
        // The IPv6 edge vision binds per-customer [::/64 /128]:443 and
        // forwards to the customer's WG IP. This exercises that exact
        // path: an IPv6 loopback listen_addr through the forwarder to
        // an IPv4 upstream. The demo deployment (edge.nix) puts a
        // real /128 from the routed /64 in listen_addr; this test
        // proves the bracket-notation IPv6 bind + forward cannot
        // silently regress.
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        tokio::spawn(echo_tcp(upstream));

        let (f, tx, handle) = spawn_forwarder(Config {
            forwards: vec![Forward {
                listen_addr: "[::1]:0".to_string(),
                proto: Proto::Tcp,
                dest_addr: format!("127.0.0.1:{upstream_port}"),
            }],
            ..Config::default()
        });
        let fwd_port = bound_port(&f).await;

        let got = round_trip_tcp_v6(fwd_port, b"ping").await;
        assert_eq!(got, b"ping");

        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn run_udp_forward() {
        let upstream = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        let upstream = Arc::new(upstream);
        tokio::spawn(echo_udp(upstream.clone()));

        let (f, tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(
                Proto::Udp,
                "127.0.0.1:0",
                &format!("127.0.0.1:{upstream_port}"),
            )],
            udp_flow_idle: std::time::Duration::from_secs(60),
            ..Config::default()
        });
        let fwd_port = bound_port(&f).await;

        let got = round_trip_udp(fwd_port, b"ping").await;
        assert_eq!(got, b"ping");

        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn run_graceful_shutdown_no_inflight() {
        let (_f, tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:0", "127.0.0.1:1")],
            shutdown_timeout: std::time::Duration::from_secs(2),
            ..Config::default()
        });
        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn run_retry_until_shutdown_cancel() {
        // Bind to a non-routable TEST-NET address: the bind fails with
        // EADDRNOTAVAIL (transient) and retries until the shutdown
        // signal cancels it. Mirrors Go TestRun_RetryUntilContextCancel.
        let (_f, tx, handle) = spawn_forwarder(Config {
            forwards: vec![Forward {
                listen_addr: "192.0.2.1:80".to_string(),
                proto: Proto::Tcp,
                dest_addr: "127.0.0.1:80".to_string(),
            }],
            bind_timeout: std::time::Duration::from_secs(30),
            ..Config::default()
        });
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        tx.send(true).unwrap();
        let err = handle.await.unwrap().unwrap_err();
        assert!(matches!(err, RunError::Bind { source: BindError::Cancelled, .. }));
    }

    #[tokio::test]
    async fn stats_records_bound_forward() {
        let cfg = Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:0", "127.0.0.1:1")],
            component: "cococoir-edge".to_string(),
            ..Config::default()
        };
        let f = Arc::new(Forwarder::new(cfg.clone()).unwrap());
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

        let fwd_port = bound_port(&f).await;
        let stats = f.stats();
        assert_eq!(stats.component, "cococoir-edge");
        assert_eq!(stats.forwards.len(), 1);
        assert!(stats.forwards[0].bound);
        assert!(stats.forwards[0].bound_at.is_some());
        assert!(stats.forwards[0].last_error.is_none());
        assert_eq!(stats.forwards[0].listen_addr, format!("127.0.0.1:{fwd_port}"));
        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn stats_records_bind_error() {
        // Non-transient bind error (port in use) surfaces immediately
        // as RunError and records last_error in stats. The occupied
        // listener stays bound for the whole test — no released port,
        // so nothing can race it.
        let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = occupied.local_addr().unwrap();
        let (_, _tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(Proto::Tcp, &addr.to_string(), "127.0.0.1:80")],
            bind_timeout: std::time::Duration::from_millis(200),
            ..Config::default()
        });
        let err = handle.await.unwrap().unwrap_err();
        assert!(matches!(
            err,
            RunError::Bind {
                source: BindError::NonTransient { .. },
                ..
            }
        ));
    }

    #[tokio::test]
    async fn stats_tcp_connection_count() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        tokio::spawn(echo_tcp(upstream));

        let f = Arc::new(
            Forwarder::new(Config {
                forwards: vec![forward(
                    Proto::Tcp,
                    "127.0.0.1:0",
                    &format!("127.0.0.1:{upstream_port}"),
                )],
                ..Config::default()
            })
            .unwrap(),
        );
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

        let fwd_port = bound_port(&f).await;
        let _ = round_trip_tcp(fwd_port, b"ping").await;
        let _ = round_trip_tcp(fwd_port, b"ping").await;

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if f.stats().tcp_connections == 0 {
                tx.send(true).unwrap();
                handle.await.unwrap().unwrap();
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("tcp_connections never returned to 0: {:?}", f.stats().tcp_connections);
    }

    #[tokio::test]
    async fn stats_udp_flow_count() {
        let upstream = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        let upstream = Arc::new(upstream);
        tokio::spawn(echo_udp(upstream.clone()));

        let f = Arc::new(
            Forwarder::new(Config {
                forwards: vec![forward(
                    Proto::Udp,
                    "127.0.0.1:0",
                    &format!("127.0.0.1:{upstream_port}"),
                )],
                udp_flow_idle: std::time::Duration::from_millis(100),
                ..Config::default()
            })
            .unwrap(),
        );
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

        let fwd_port = bound_port(&f).await;
        let _ = round_trip_udp(fwd_port, b"ping").await;

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if f.stats().udp_flows == 0 {
                tx.send(true).unwrap();
                handle.await.unwrap().unwrap();
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        panic!("udp_flows never returned to 0 after idle timeout: {:?}", f.stats().udp_flows);
    }

    #[tokio::test]
    async fn stats_forwards_slice_is_copy() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr: SocketAddr = upstream.local_addr().unwrap();
        let f = Arc::new(
            Forwarder::new(Config {
                forwards: vec![forward(Proto::Tcp, "127.0.0.1:0", &addr.to_string())],
                ..Config::default()
            })
            .unwrap(),
        );
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

        let _ = bound_port(&f).await;

        let mut stats = f.stats();
        stats.forwards[0].bound = false;
        stats.forwards[0].last_error = Some("mutated by test".to_string());

        let again = f.stats();
        assert!(again.forwards[0].bound, "mutating Stats().forwards leaked into forwarder state");
        assert!(again.forwards[0].last_error.is_none(), "last_error leaked through");

        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn stats_initial_state() {
        let f = Forwarder::new(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:1", "127.0.0.1:1")],
            ..Config::default()
        })
        .unwrap();
        let stats = f.stats();
        assert_eq!(stats.component, "cococoir");
        assert_eq!(stats.tcp_connections, 0);
        assert_eq!(stats.udp_flows, 0);
        assert!(stats.forwards.is_empty());
        assert!(stats.uptime_seconds >= 0.0);
    }

    // ── live mutation (add/remove) tests ──────────────────────────

    #[tokio::test]
    async fn add_forward_binds_and_serves() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        tokio::spawn(echo_tcp(upstream));

        let f = Arc::new(Forwarder::new(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:1", "127.0.0.1:1")], // dummy, not run
            bind_timeout: std::time::Duration::from_secs(5),
            ..Config::default()
        })
        .unwrap());

        // The forwarder was never `run()` — add_forward must start a
        // live listener on its own. The `:0` listen lets the kernel
        // pick the port; stats records the actual bound address.
        let fwd = Forward {
            listen_addr: "127.0.0.1:0".to_string(),
            proto: Proto::Tcp,
            dest_addr: format!("127.0.0.1:{upstream_port}"),
        };
        f.add_forward(&fwd).await.expect("add_forward");
        let fwd_port = bound_port(&f).await;

        let got = round_trip_tcp(fwd_port, b"live-add").await;
        assert_eq!(got, b"live-add");
        assert!(f.stats().forwards.iter().any(|s| s.bound && s.listen_addr == format!("127.0.0.1:{fwd_port}")));
    }

    #[tokio::test]
    async fn remove_forward_stops_serving() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        tokio::spawn(echo_tcp(upstream));

        let f = Arc::new(Forwarder::new(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:1", "127.0.0.1:1")],
            bind_timeout: std::time::Duration::from_secs(5),
            ..Config::default()
        })
        .unwrap());
        let fwd = Forward {
            listen_addr: "127.0.0.1:0".to_string(),
            proto: Proto::Tcp,
            dest_addr: format!("127.0.0.1:{upstream_port}"),
        };
        f.add_forward(&fwd).await.unwrap();
        let fwd_port = bound_port(&f).await;
        let _ = round_trip_tcp(fwd_port, b"before").await;

        assert!(f.remove_forward(&fwd));
        // The listener is gone: a fresh connect must fail.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut refused = false;
        while std::time::Instant::now() < deadline {
            if TcpStream::connect(("127.0.0.1", fwd_port)).await.is_err() {
                refused = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(refused, "listener still accepting after remove_forward");
        assert!(!f.stats().forwards.iter().any(|s| s.listen_addr == format!("127.0.0.1:{fwd_port}")));
    }

    #[tokio::test]
    async fn remove_forward_returns_false_for_unknown() {
        let f = Arc::new(Forwarder::new(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:1", "127.0.0.1:1")],
            ..Config::default()
        })
        .unwrap());
        let fwd = Forward {
            listen_addr: "127.0.0.1:9".to_string(),
            proto: Proto::Tcp,
            dest_addr: "127.0.0.1:9".to_string(),
        };
        assert!(!f.remove_forward(&fwd));
    }

    #[tokio::test]
    async fn add_forward_twice_is_noop() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_port = upstream.local_addr().unwrap().port();
        tokio::spawn(echo_tcp(upstream));

        let f = Arc::new(Forwarder::new(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:1", "127.0.0.1:1")],
            bind_timeout: std::time::Duration::from_secs(5),
            ..Config::default()
        })
        .unwrap());
        let fwd = Forward {
            listen_addr: "127.0.0.1:0".to_string(),
            proto: Proto::Tcp,
            dest_addr: format!("127.0.0.1:{upstream_port}"),
        };
        f.add_forward(&fwd).await.unwrap();
        f.add_forward(&fwd).await.unwrap(); // no-op, must not error
        let fwd_port = bound_port(&f).await;
        let got = round_trip_tcp(fwd_port, b"twice").await;
        assert_eq!(got, b"twice");
    }

    #[tokio::test]
    async fn freebind_binds_non_local_ipv6_address() {
        // A /128 that is NOT assigned to any local interface cannot
        // be bound by a plain bind (EADDRNOTAVAIL), but IPV6_FREEBIND
        // accepts it. 2001:db8::1 is the documentation range — never
        // assigned to a local interface. This is the exact class of
        // address the edge binds: a customer /128 inside the routed
        // /64 that is never added to an interface.
        let f = Arc::new(Forwarder::new(Config {
            forwards: vec![forward(Proto::Tcp, "127.0.0.1:1", "127.0.0.1:1")],
            bind_timeout: std::time::Duration::from_secs(5),
            ..Config::default()
        })
        .unwrap());
        // Sanity: a plain bind must FAIL for this address (proving it
        // is genuinely non-local, so the test is meaningful).
        let plain = tokio::net::TcpListener::bind("2001:db8::1:0").await;
        assert!(plain.is_err(), "2001:db8::1 should not be locally bindable");

        let fwd = Forward {
            listen_addr: "[2001:db8::1]:8443".to_string(),
            proto: Proto::Tcp,
            dest_addr: "127.0.0.1:1".to_string(),
        };
        f.add_forward(&fwd).await.expect("freebind binds non-local /128");
        let stats = f.stats();
        assert!(stats.forwards.iter().any(|s| s.bound && s.listen_addr == "[2001:db8::1]:8443"));
        f.remove_forward(&fwd);
    }
}
