// SPDX-License-Identifier: AGPL-3.0-or-later
//! fortress-site: the edge box's public site — the topcoat + axum
//! presentation of the control plane — and, since the T7 cutover, the
//! edge process itself. It boots the shared L4 forwarder and the
//! store-held WG identity through `init_globals` (the same call the
//! legacy `fortress-edge` binary makes), then serves the customer
//! surfaces on one listener.
//!
//! Flags:
//!   --redis-url redis://127.0.0.1:6379
//!   --subnet 2a01:4f8:c17:1::/64      (the box's routed subnet)
//!   --wg-subnet 10.10.0.0/24          (WG tunnel net, edge .1, customers .2+)
//!   --addr 0.0.0.0:8082               (pages + /api + /healthz on one port)
//!   --ipv6-iface eth0                 (interface holding the routed /64)
//!   --dummy                           (dev only: mock WG/DNS, console
//!                                      mailer; compiles ONLY into debug builds)
#![deny(unsafe_code)]

use fortress_controlplane::controlplane::secret::redis_url;
use fortress_controlplane::{
    control_plane, init_globals, install_crypto_provider, wait_for_signal, Subnet64, WgSubnet,
};
use fortress_site::SiteBackend;

/// The flag only exists under `cfg!(debug_assertions)`, so a shipped
/// (release) site cannot be put into dummy mode: `--dummy` hits the
/// unknown-flag arm there instead.
#[cfg(debug_assertions)]
const USAGE: &str = "usage: fortress-site [--dummy] --subnet /64 [--redis-url URL] [--wg-subnet NET] [--addr ADDR] [--ipv6-iface IFACE]";
#[cfg(not(debug_assertions))]
const USAGE: &str = "usage: fortress-site --subnet /64 [--redis-url URL] [--wg-subnet NET] [--addr ADDR] [--ipv6-iface IFACE]";

struct SiteArgs {
    redis_url: Option<String>,
    subnet: String,
    wg_subnet: String,
    addr: String,
    ipv6_iface: Option<String>,
    dummy: bool,
}

/// Parse the flag list. Value-less `--dummy` is recognized only under
/// `cfg!(debug_assertions)`, so a shipped site cannot enter dummy mode:
/// there it hits the unknown-flag arm and errors.
fn parse_args(args: impl Iterator<Item = String>) -> Result<SiteArgs, String> {
    let mut out = SiteArgs {
        redis_url: None,
        subnet: String::new(),
        wg_subnet: "10.10.0.0/24".to_string(),
        addr: "0.0.0.0:8082".to_string(),
        ipv6_iface: None,
        dummy: false,
    };
    let mut args = args;
    while let Some(arg) = args.next() {
        #[cfg(debug_assertions)]
        if arg == "--dummy" {
            out.dummy = true;
            continue;
        }
        let value = args
            .next()
            .ok_or_else(|| format!("{arg} requires a value\n{USAGE}"))?;
        match arg.as_str() {
            "--redis-url" => out.redis_url = Some(value),
            "--subnet" => out.subnet = value,
            "--wg-subnet" => out.wg_subnet = value,
            "--addr" => out.addr = value,
            "--ipv6-iface" => out.ipv6_iface = Some(value),
            other => return Err(format!("unknown flag {other}\n{USAGE}")),
        }
    }
    if out.subnet.is_empty() {
        return Err(format!(
            "missing --subnet (the edge box's routed subnet, e.g. 2a01:4f8:c17:1::/64)\n{USAGE}"
        ));
    }
    Ok(out)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    install_crypto_provider();

    let args = parse_args(std::env::args().skip(1))?;
    let subnet = Subnet64::from_str(&args.subnet).map_err(|err| format!("--subnet: {err}"))?;
    let wg_subnet =
        WgSubnet::from_str(&args.wg_subnet).map_err(|err| format!("--wg-subnet: {err}"))?;
    if args.dummy {
        // Loud on purpose: this box is NOT routing traffic. Printed
        // before any boot-secret access — dummy mode never touches them.
        eprintln!(
            "\n============================================================\n\
             !!! FORTRESS-SITE IS RUNNING IN DUMMY/DEV MODE (--dummy) !!!\n\
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
    init_globals(&store_url, subnet, wg_subnet, args.ipv6_iface, args.dummy).await?;

    let backend: &'static SiteBackend = Box::leak(Box::new(SiteBackend {
        cp: control_plane(),
        mailer: fortress_controlplane::controlplane::mail::mailer(),
    }));

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    // DNS reconcile loop: verify every customer's AAAA records against
    // real resolution and re-apply drift. First pass ~30s after boot,
    // then every 2h. DNS is cosmetic to the tunnel, so a failing pass
    // logs and retries — never kills the site.
    let reconcile_task = tokio::spawn(reconcile_loop(shutdown_rx.clone()));
    let signal_task = tokio::spawn(async move {
        wait_for_signal().await;
        tracing::info!("received signal, shutting down");
        let _ = shutdown_tx.send(true);
    });

    let app = fortress_site::server::app(backend);
    let listener = tokio::net::TcpListener::bind(&args.addr).await?;
    eprintln!("fortress-site listening on http://{}", args.addr);
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_guard(shutdown_rx))
        .await?;

    let _ = tokio::join!(reconcile_task, signal_task);
    Ok(())
}

/// Verify every customer's AAAA records against real resolution and
/// re-apply drift: first pass ~30s after boot, then every 2h.
async fn reconcile_loop(mut shutdown: tokio::sync::watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(7200));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let initial = tokio::time::sleep(std::time::Duration::from_secs(30));
    tokio::pin!(initial);
    loop {
        tokio::select! {
            _ = &mut initial => {}
            _ = shutdown.changed() => return,
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
            _ = shutdown.changed() => return,
        }
    }
}

/// A future that resolves when the shutdown signal fires — feeds
/// axum's `with_graceful_shutdown`.
async fn shutdown_guard(mut rx: tokio::sync::watch::Receiver<bool>) {
    let _ = rx.wait_for(|v| *v).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(argv: &[&str]) -> Result<SiteArgs, String> {
        parse_args(argv.iter().map(|s| s.to_string()))
    }

    /// `--dummy` is value-less, so it must never swallow the following
    /// argument (e.g. `--subnet`).
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
    fn addr_defaults_to_the_site_port() {
        let args = parse(&["--subnet", "fd00::/64"]).expect("parses");
        assert_eq!(args.addr, "0.0.0.0:8082");
        assert_eq!(args.wg_subnet, "10.10.0.0/24");
    }
}
