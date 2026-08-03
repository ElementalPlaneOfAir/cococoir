// SPDX-License-Identifier: AGPL-3.0-or-later
//! Shared cmd entry point for `cococoir-edge` and `cococoir-client`.
//!
//! The Go original duplicated this ~85-line main across both
//! binaries; this single function is the DRY replacement. Each binary
//! is a thin wrapper:
//!
//! ```rust,ignore
//! #[tokio::main]
//! async fn main() {
//!     std::process::exit(cococoir::app::run("cococoir-edge", "/etc/cococoir-edge.json").await);
//! }
//! ```
//!
//! Flow: parse flags, init logger, read the JSON config, build the
//! forwarder, start the health server, then block on the forwarder
//! until SIGINT/SIGTERM. Both the forwarder and the health server
//! stop on the same shutdown signal.

use std::sync::Arc;

use serde::Deserialize;
use tokio::sync::watch;
use tracing::{error, info};
use tracing::span;

use crate::forwarder::{Config, Forward, Forwarder};
use crate::health::{HealthServer, StatusFunc};
use crate::logger;

/// The on-disk config file shape. Matches the Go binaries'
/// `configFile` struct; `deny_unknown_fields` rejects a typo'd key
/// at startup instead of silently dropping it.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    forwards: Vec<Forward>,
}

/// CLI flags, mirroring the Go `flag` defaults.
#[derive(Debug)]
struct Flags {
    config_path: String,
    log_format: logger::Format,
    health_addr: String,
}

/// Shared entry point. `component` and `default_config` come from the
/// binary wrapper. Returns the process exit code.
pub async fn run(component: &str, default_config: &str) -> i32 {
    let flags = match parse_flags(component, default_config) {
        Ok(flags) => flags,
        Err(err) => {
            eprintln!("{err}");
            eprintln!("usage: {component} -config PATH -log-format text|json -health-addr ADDR");
            return 1;
        }
    };
    logger::init(flags.log_format);
    let span = span!(tracing::Level::INFO, "cococoir", component = component);
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
    let forwarder = match Forwarder::new(Config {
        forwards: cfg.forwards,
        component: component.to_string(),
        ..Config::default()
    }) {
        Ok(f) => Arc::new(f),
        Err(err) => {
            error!(err = %err, "forwarder init failed");
            return 1;
        }
    };

    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // Health server. The status closure reads the forwarder's stats
    // on every request. Same decoupling as Go: health never imports
    // forwarder types.
    let status_func: StatusFunc = {
        let f = forwarder.clone();
        Arc::new(move || serde_json::to_value(f.stats()).unwrap_or(serde_json::Value::Null))
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

    let forwarder_run = forwarder.clone();
    let forwarder_shutdown = shutdown_rx.clone();
    let code = match forwarder_run.run(forwarder_shutdown).await {
        Ok(()) => 0,
        Err(err) => {
            error!(err = %err, "forwarder exited with error");
            1
        }
    };

    // The forwarder's run() only returns after its shutdown drain;
    // the health server and signal task stop on the same signal.
    let _ = health_task.await;
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

/// Parses `-config`, `-log-format`, and `-health-addr` from argv,
/// applying the binary's defaults for unset flags.
fn parse_flags(component: &str, default_config: &str) -> Result<Flags, String> {
    parse_flag_args(component, default_config, std::env::args().skip(1).collect())
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

    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let value = args.next().ok_or_else(|| format!("{component}: flag {arg} requires a value"))?;
        match arg.as_str() {
            "-config" => config_path = value,
            "-log-format" => log_format = value,
            "-health-addr" => health_addr = value,
            other => return Err(format!("{component}: unknown flag {other}")),
        }
    }
    let log_format = logger::Format::parse(&log_format).map_err(|err| err.to_string())?;
    Ok(Flags {
        config_path,
        log_format,
        health_addr,
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
        let flags = parse_flag_args("cococoir-edge", "/etc/cococoir-edge.json", args(&[])).unwrap();
        assert_eq!(flags.config_path, "/etc/cococoir-edge.json");
        assert_eq!(flags.log_format, logger::Format::Text);
        assert_eq!(flags.health_addr, "127.0.0.1:9090");
    }

    #[test]
    fn parse_flags_custom() {
        let flags = parse_flag_args(
            "cococoir-edge",
            "/etc/cococoir-edge.json",
            args(&["-config", "/tmp/x.json", "-log-format", "json", "-health-addr", "0.0.0.0:9090"]),
        )
        .unwrap();
        assert_eq!(flags.config_path, "/tmp/x.json");
        assert_eq!(flags.log_format, logger::Format::Json);
        assert_eq!(flags.health_addr, "0.0.0.0:9090");
    }

    #[test]
    fn parse_flags_rejects_unknown_flag() {
        let err = parse_flag_args("cococoir-edge", "/etc/cococoir-edge.json", args(&["-bogus", "1"])).unwrap_err();
        assert!(err.contains("unknown flag"));
    }

    #[test]
    fn parse_flags_rejects_unknown_format() {
        let err = parse_flag_args("cococoir-edge", "/etc/cococoir-edge.json", args(&["-log-format", "yaml"])).unwrap_err();
        assert!(err.contains("unknown format"));
    }

    #[test]
    fn config_file_rejects_unknown_field() {
        let err = serde_json::from_str::<ConfigFile>(r#"{"forwards":[],"bogus":1}"#).unwrap_err();
        assert!(err.to_string().contains("unknown field"));
    }
}
