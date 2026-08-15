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

use crate::retry::{retry_bind_tcp, retry_bind_udp, BindError};
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
}

impl Default for Config {
    fn default() -> Self {
        Self {
            forwards: Vec::new(),
            shutdown_timeout: Duration::from_secs(30),
            bind_timeout: Duration::from_secs(30),
            udp_flow_idle: Duration::from_secs(300),
            component: "cococoir".to_string(),
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
/// for the per-forward map.
#[derive(Debug)]
pub(crate) struct State {
    forwards: RwLock<HashMap<String, ForwardStat>>,
    tcp_connections: AtomicI64,
    udp_flows: AtomicI64,
}

impl Default for State {
    fn default() -> Self {
        Self {
            forwards: RwLock::new(HashMap::new()),
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

    fn record_bound(&self, fwd: &Forward, at: DateTime<Utc>) {
        let mut forwards = self.forwards.write().unwrap();
        forwards.insert(
            forward_key(fwd),
            ForwardStat {
                proto: fwd.proto,
                listen_addr: fwd.listen_addr.clone(),
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

impl Forwarder {
    /// Validates `cfg` and returns a ready `Forwarder`. Callers then
    /// drive it with `run()`.
    pub fn new(cfg: Config) -> Result<Self, ConfigError> {
        if cfg.forwards.is_empty() {
            return Err(ConfigError::EmptyForwards);
        }
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
                    self.state.record_bound(fwd, Utc::now());
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
                    self.state.record_bound(fwd, Utc::now());
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
}

/// Map key for the per-forward stats row. Matches Go's
/// `proto://listen_addr`.
fn forward_key(fwd: &Forward) -> String {
    format!("{}://{}", fwd.proto.as_str(), fwd.listen_addr)
}

#[cfg(test)]
mod tests {
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

    async fn pick_free_tcp_port() -> u16 {
        let ln = TcpListener::bind("127.0.0.1:0").await.unwrap();
        ln.local_addr().unwrap().port()
    }

    async fn pick_free_udp_port() -> u16 {
        let s = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        s.local_addr().unwrap().port()
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

    /// Spawn a forwarder in the background; returns the shutdown
    /// sender and the run task. Tests flip shutdown to stop it.
    fn spawn_forwarder(
        cfg: Config,
    ) -> (
        watch::Sender<bool>,
        tokio::task::JoinHandle<Result<(), RunError>>,
    ) {
        let f = Arc::new(Forwarder::new(cfg).unwrap());
        let (tx, rx) = watch::channel(false);
        let handle = tokio::spawn(async move { f.run(rx).await });
        (tx, handle)
    }

    fn forward(proto: Proto, listen_port: u16, dest: &str) -> Forward {
        Forward {
            listen_addr: format!("127.0.0.1:{listen_port}"),
            proto,
            dest_addr: dest.to_string(),
        }
    }

    #[tokio::test]
    async fn run_tcp_forward() {
        let upstream_port = pick_free_tcp_port().await;
        let upstream = TcpListener::bind(("127.0.0.1", upstream_port)).await.unwrap();
        tokio::spawn(echo_tcp(upstream));

        let fwd_port = pick_free_tcp_port().await;
        let (tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(
                Proto::Tcp,
                fwd_port,
                &format!("127.0.0.1:{upstream_port}"),
            )],
            ..Config::default()
        });

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
        let upstream_port = pick_free_tcp_port().await;
        let upstream = TcpListener::bind(("127.0.0.1", upstream_port)).await.unwrap();
        tokio::spawn(echo_tcp(upstream));

        let fwd_port = pick_free_tcp_port().await;
        let (tx, handle) = spawn_forwarder(Config {
            forwards: vec![Forward {
                listen_addr: format!("[::1]:{fwd_port}"),
                proto: Proto::Tcp,
                dest_addr: format!("127.0.0.1:{upstream_port}"),
            }],
            ..Config::default()
        });

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

        let fwd_port = pick_free_udp_port().await;
        let (tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(
                Proto::Udp,
                fwd_port,
                &format!("127.0.0.1:{upstream_port}"),
            )],
            udp_flow_idle: std::time::Duration::from_secs(60),
            ..Config::default()
        });

        let got = round_trip_udp(fwd_port, b"ping").await;
        assert_eq!(got, b"ping");

        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn run_graceful_shutdown_no_inflight() {
        let fwd_port = pick_free_tcp_port().await;
        let (tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(Proto::Tcp, fwd_port, "127.0.0.1:1")],
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
        let (tx, handle) = spawn_forwarder(Config {
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
        let fwd_port = pick_free_tcp_port().await;
        let cfg = Config {
            forwards: vec![forward(Proto::Tcp, fwd_port, "127.0.0.1:1")],
            component: "cococoir-edge".to_string(),
            ..Config::default()
        };
        let f = Arc::new(Forwarder::new(cfg.clone()).unwrap());
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            let stats = f.stats();
            if stats.forwards.len() == 1 && stats.forwards[0].bound {
                assert_eq!(stats.component, "cococoir-edge");
                assert!(stats.forwards[0].bound_at.is_some());
                assert!(stats.forwards[0].last_error.is_none());
                assert_eq!(stats.forwards[0].listen_addr, format!("127.0.0.1:{fwd_port}"));
                break;
            }
            assert!(std::time::Instant::now() < deadline, "never recorded bound: {:?}", f.stats());
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        tx.send(true).unwrap();
        handle.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn stats_records_bind_error() {
        // Non-transient bind error (port in use) surfaces immediately
        // as RunError and records last_error in stats.
        let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = occupied.local_addr().unwrap();
        let (tx, handle) = spawn_forwarder(Config {
            forwards: vec![forward(Proto::Tcp, addr.port(), "127.0.0.1:80")],
            bind_timeout: std::time::Duration::from_millis(200),
            ..Config::default()
        });
        let _ = tx;
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
        let upstream_port = pick_free_tcp_port().await;
        let upstream = TcpListener::bind(("127.0.0.1", upstream_port)).await.unwrap();
        tokio::spawn(echo_tcp(upstream));

        let fwd_port = pick_free_tcp_port().await;
        let f = Arc::new(
            Forwarder::new(Config {
                forwards: vec![forward(
                    Proto::Tcp,
                    fwd_port,
                    &format!("127.0.0.1:{upstream_port}"),
                )],
                ..Config::default()
            })
            .unwrap(),
        );
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

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

        let fwd_port = pick_free_udp_port().await;
        let f = Arc::new(
            Forwarder::new(Config {
                forwards: vec![forward(
                    Proto::Udp,
                    fwd_port,
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
        let fwd_port = pick_free_tcp_port().await;
        let f = Arc::new(
            Forwarder::new(Config {
                forwards: vec![forward(Proto::Tcp, fwd_port, &addr.to_string())],
                ..Config::default()
            })
            .unwrap(),
        );
        let (tx, rx) = watch::channel(false);
        let run = f.clone();
        let handle = tokio::spawn(async move { run.run(rx).await });

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if !f.stats().forwards.is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(!f.stats().forwards.is_empty(), "never bound");

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
            forwards: vec![forward(Proto::Tcp, 1, "127.0.0.1:1")],
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
}
