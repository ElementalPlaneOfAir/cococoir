// SPDX-License-Identifier: AGPL-3.0-or-later
//! cococoir-edge: the edge box's single process.
//!
//! One tokio app runs the L4 forwarder (live add/remove via
//! `IPV6_FREEBIND`), the control plane HTTP API (signup/delete),
//! and the health/status server — sharing the routing table and one
//! shutdown signal. No IPC, no reload: signups mutate the forwarder
//! directly in-process.
//!
//! On boot it rehydrates the routing table + live forwards from Redis
//! before accepting traffic (the obligatory reconcile-on-boot), so a
//! crash never leaves a customer registered but not forwarded.
//!
//! Flags:
//!   --redis-url redis://127.0.0.1:6379
//!   --subnet 2a01:4f8:c17:1::/64      (the box's routed subnet)
//!   --wg-subnet 10.10.0.0/24          (WG tunnel net, edge .1, customers .2+)
//!   --api-addr 0.0.0.0:8081           (control plane HTTP)
//!   --health-addr 127.0.0.1:9090      (/healthz /readyz /status)
#![deny(unsafe_code)]

use std::sync::Arc;

use cococoir::controlplane::{Subnet64, WgSubnet, forwarder, init_globals};
use cococoir::health::{HealthServer, StatusFunc};

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    let mut redis_url = "redis://127.0.0.1:6379".to_string();
    let mut subnet = String::new();
    let mut wg_subnet = "10.10.0.0/24".to_string();
    let mut api_addr = "0.0.0.0:8081".to_string();
    let mut health_addr = "127.0.0.1:9090".to_string();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args.next().ok_or_else(|| {
            std::io::Error::other(format!("{arg} requires a value"))
        })?;
        match arg.as_str() {
            "--redis-url" => redis_url = value,
            "--subnet" => subnet = value,
            "--wg-subnet" => wg_subnet = value,
            "--api-addr" => api_addr = value,
            "--health-addr" => health_addr = value,
            other => {
                eprintln!("unknown flag {other}");
                return Err(std::io::Error::other(
                    "usage: cococoir-edge --subnet /64 [--redis-url URL] [--wg-subnet NET] [--api-addr ADDR] [--health-addr ADDR]",
                ));
            }
        }
    }
    if subnet.is_empty() {
        return Err(std::io::Error::other(
            "missing --subnet (the edge box's routed subnet, e.g. 2a01:4f8:c17:1::/64)",
        ));
    }

    let subnet = Subnet64::from_str(&subnet).map_err(std::io::Error::other)?;
    let wg_subnet = WgSubnet::from_str(&wg_subnet).map_err(std::io::Error::other)?;

    // Obligatory reconcile-on-boot: initialize the process globals,
    // hydrating the routing table + forwarder from Redis (and installing
    // the edge's WG identity into wg0) before serving, so durable state
    // and live state agree. Returns Err (not a crash) if Redis is down.
    init_globals(&redis_url, subnet, wg_subnet)
        .await
        .map_err(|err| std::io::Error::other(format!("control plane init: {err}")))?;

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    // Control plane HTTP (signup/delete/customers/pubkey) on --api-addr.
    let api = cococoir::controlplane::app();
    let api_addr2 = api_addr.clone();
    let api_shutdown = shutdown_rx.clone();
    let api_task = tokio::spawn(async move {
        let listener = match tokio::net::TcpListener::bind(&api_addr2).await {
            Ok(l) => l,
            Err(err) => {
                tracing::error!(addr = %api_addr2, err = %err, "api bind failed");
                return;
            }
        };
        let acceptor = poem::listener::TcpAcceptor::from_tokio(listener)
            .expect("tokio listener converts to poem acceptor");
        if let Err(err) = poem::Server::new_with_acceptor(acceptor)
            .run_with_graceful_shutdown(api, shutdown_guard(api_shutdown), None)
            .await
        {
            tracing::error!(err = %err, "api server exited with error");
        }
    });

    // Health/status on --health-addr. The status closure reads the
    // forwarder's live state on every request.
    let status_func: StatusFunc = Arc::new(move || {
        serde_json::to_value(forwarder().stats()).unwrap_or(serde_json::Value::Null)
    });
    let health_shutdown = shutdown_rx.clone();
    let health_task = tokio::spawn(async move {
        let server = HealthServer::new(health_addr.clone(), status_func);
        if let Err(err) = server.run(health_shutdown).await {
            tracing::error!(err = %err, "health server exited with error");
        }
    });

    // Signal task: SIGINT/SIGTERM → shutdown channel.
    let signal_task = tokio::spawn(async move {
        wait_for_signal().await;
        tracing::info!("received signal, shutting down");
        let _ = shutdown_tx.send(true);
    });

    let _ = tokio::try_join!(api_task, health_task, signal_task);
    Ok(())
}

/// Waits for SIGINT or SIGTERM.
async fn wait_for_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigint = signal(SignalKind::interrupt()).expect("install SIGINT handler");
    let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    tokio::select! {
        _ = sigint.recv() => {}
        _ = sigterm.recv() => {}
    }
}

/// A future that resolves when the shutdown signal fires — feeds
/// poem's `run_with_graceful_shutdown`.
async fn shutdown_guard(mut rx: tokio::sync::watch::Receiver<bool>) {
    let _ = rx.wait_for(|v| *v).await;
}
