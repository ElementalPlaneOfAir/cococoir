// SPDX-License-Identifier: AGPL-3.0-or-later
//! fortress-edge: the edge box's single process.
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
//!   --api-addr 0.0.0.0:8081           (control plane HTTP + /healthz /readyz /status)
//!   --dummy                           (dev only: mock WG/DNS, console mailer;
//!                                      compiles ONLY into debug builds)
#![deny(unsafe_code)]

use fortress_controlplane::controlplane::secret::redis_url;
use fortress_controlplane::{control_plane, init_globals, Subnet64, WgSubnet};

/// The flag only exists under `cfg!(debug_assertions)`, so a shipped
/// (release) edge cannot be put into dummy mode: `--dummy` hits the
/// unknown-flag arm there instead. Release binaries never advertise it.
#[cfg(debug_assertions)]
const USAGE: &str = "usage: fortress-edge [--dummy] --subnet /64 [--redis-url URL] [--wg-subnet NET] [--api-addr ADDR] [--ipv6-iface IFACE]";
#[cfg(not(debug_assertions))]
const USAGE: &str = "usage: fortress-edge --subnet /64 [--redis-url URL] [--wg-subnet NET] [--api-addr ADDR] [--ipv6-iface IFACE]";

/// The parsed CLI flags. `dummy` is set only in debug builds.
struct EdgeArgs {
    redis_url: Option<String>,
    subnet: String,
    wg_subnet: String,
    api_addr: String,
    ipv6_iface: Option<String>,
    dummy: bool,
}

/// Parse the flag list. Value-less `--dummy` is recognized only under
/// `cfg!(debug_assertions)`, so a shipped (release) edge cannot enter
/// dummy mode: there it hits the unknown-flag arm and errors.
fn parse_args(args: impl Iterator<Item = String>) -> Result<EdgeArgs, std::io::Error> {
    let mut out = EdgeArgs {
        redis_url: None,
        subnet: String::new(),
        wg_subnet: "10.10.0.0/24".to_string(),
        api_addr: "0.0.0.0:8081".to_string(),
        ipv6_iface: None,
        dummy: false,
    };
    let mut args = args;
    while let Some(arg) = args.next() {
        // Value-less flag, compiled out of release builds so a shipped
        // edge can never enable dummy mode.
        #[cfg(debug_assertions)]
        if arg == "--dummy" {
            out.dummy = true;
            continue;
        }
        let value = args
            .next()
            .ok_or_else(|| std::io::Error::other(format!("{arg} requires a value")))?;
        match arg.as_str() {
            "--redis-url" => out.redis_url = Some(value),
            "--subnet" => out.subnet = value,
            "--wg-subnet" => out.wg_subnet = value,
            "--api-addr" => out.api_addr = value,
            "--ipv6-iface" => out.ipv6_iface = Some(value),
            other => {
                eprintln!("unknown flag {other}");
                return Err(std::io::Error::other(USAGE));
            }
        }
    }
    if out.subnet.is_empty() {
        return Err(std::io::Error::other(
            "missing --subnet (the edge box's routed subnet, e.g. 2a01:4f8:c17:1::/64)",
        ));
    }
    Ok(out)
}

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    // Install the rustls crypto provider before anything builds a rustls
    // client (redis rediss, reqwest). With multiple provider features in
    // the dep tree, rustls refuses to pick one itself and aborts — that
    // was the edge crash-looping on boot (exit 101, restart counter N).
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("rustls crypto provider must install exactly once");

    let args = parse_args(std::env::args().skip(1))?;
    let subnet = Subnet64::from_str(&args.subnet).map_err(std::io::Error::other)?;
    let wg_subnet = WgSubnet::from_str(&args.wg_subnet).map_err(std::io::Error::other)?;
    if args.dummy {
        // Dev/dummy mode: no wg0, no DNS provider, no SMTP — only Redis.
        // Loud on purpose: this box is NOT routing traffic. Printed
        // before any boot-secret access — dummy mode never touches them.
        eprintln!(
            "\n============================================================\n\
             !!! FORTRESS-EDGE IS RUNNING IN DUMMY/DEV MODE (--dummy) !!!\n\
             This is NOT a production edge: no wg0, no DNS provider, no SMTP.\n\
             It shares the forwarder, Redis store, and HTTP wiring with prod,\n\
             but it routes nothing. --dummy compiles ONLY into debug builds\n\
             and is unreachable in the shipped binary.\n\
             ============================================================\n"
        );
    }

    // The store URL: --redis-url overrides (dev/test); production reads
    // the REDIS_URL secret — the external managed store. Dummy mode
    // defaults to localhost and never resolves the boot SECRETS.
    let store_url = match (args.redis_url, args.dummy) {
        (Some(url), _) => url,
        (None, true) => "redis://127.0.0.1:6379".to_string(),
        (None, false) => redis_url().to_string(),
    };

    // Obligatory reconcile-on-boot: initialize the process globals,
    // hydrating the routing table + forwarder from Redis (and installing
    // the edge's WG identity into wg0) before serving, so durable state
    // and live state agree. Returns Err (not a crash) if Redis is down.
    init_globals(&store_url, subnet, wg_subnet, args.ipv6_iface, args.dummy)
        .await
        .map_err(|err| std::io::Error::other(format!("control plane init: {err}")))?;

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    // Control plane HTTP (signup/delete/customers/pubkey) + health
    // (/healthz /readyz /status) on --api-addr. app() merges the health
    // endpoints into the same OpenAPI handler, so one listener serves
    // both API checks and health checks.
    let api = fortress_controlplane::app();
    let api_addr2 = args.api_addr.clone();
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

    // DNS reconcile loop: verify every customer's AAAA records against
    // real resolution and re-apply drift. First pass ~30s after boot
    // (a fresh box converges quickly), then every 2h. DNS is cosmetic
    // to the tunnel, so a failing pass logs and retries — never kills
    // the edge.
    let reconcile_shutdown = shutdown_rx.clone();
    let reconcile_task = tokio::spawn(async move {
        let mut reconcile_shutdown = reconcile_shutdown;
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(7200));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let initial = tokio::time::sleep(std::time::Duration::from_secs(30));
        tokio::pin!(initial);
        loop {
            tokio::select! {
                _ = &mut initial => {}
                _ = reconcile_shutdown.changed() => return,
            }
            match control_plane().reconcile_dns_once().await {
                Ok(reapplied) => {
                    if reapplied > 0 {
                        tracing::warn!(reapplied, "dns reconcile: re-applied records");
                    }
                }
                Err(err) => tracing::error!(err = %err, "dns reconcile pass failed"),
            }
            tokio::select! {
                _ = interval.tick() => {}
                _ = reconcile_shutdown.changed() => return,
            }
        }
    });

    // Signal task: SIGINT/SIGTERM → shutdown channel.
    let signal_task = tokio::spawn(async move {
        wait_for_signal().await;
        tracing::info!("received signal, shutting down");
        let _ = shutdown_tx.send(true);
    });

    // All three tasks must run to completion: a panic in any of them
    // is a process error (exit nonzero, systemd restarts loudly), never
    // a silently half-alive edge.
    tokio::try_join!(api_task, reconcile_task, signal_task)
        .map_err(|err| std::io::Error::other(format!("edge task failed: {err}")))?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(argv: &[&str]) -> Result<EdgeArgs, std::io::Error> {
        parse_args(argv.iter().map(|s| s.to_string()))
    }

    /// The whole point of `--dummy`: it must be a value-less flag, so it
    /// never swallows the following argument (e.g. `--subnet`).
    #[cfg(debug_assertions)]
    #[test]
    fn dummy_is_a_valueness_flag() {
        let args = parse(&["--dummy", "--subnet", "fd00::/64"]).expect("parses");
        assert!(args.dummy);
        assert_eq!(args.subnet, "fd00::/64");
    }

    /// Tripwire for the release guardrail: in a release build `--dummy`
    /// is not a flag, so a would-be black hole fails loudly instead of
    /// silently entering dummy mode.
    #[cfg(not(debug_assertions))]
    #[test]
    fn dummy_is_unreachable_in_release() {
        assert!(parse(&["--dummy", "--subnet", "fd00::/64"]).is_err());
    }

    #[test]
    fn subnet_is_required() {
        assert!(parse(&[]).is_err());
        assert!(parse(&["--dummy"]).is_err());
    }

    #[test]
    fn default_wg_subnet_and_addr() {
        let args = parse(&["--subnet", "fd00::/64"]).expect("parses");
        assert_eq!(args.wg_subnet, "10.10.0.0/24");
        assert_eq!(args.api_addr, "0.0.0.0:8081");
        assert_eq!(args.ipv6_iface, None);
    }

    #[test]
    fn unknown_flag_errors() {
        assert!(parse(&["--subnet", "fd00::/64", "--bogus", "x"]).is_err());
    }
}
