// SPDX-License-Identifier: AGPL-3.0-or-later
//! UDP forward serving: flow tracking with per-flow idle expiry.
//!
//! Port of Go `internal/forwarder/udp.go`, with a structural
//! improvement: Go keeps one shared `flows` map mutated by the read
//! loop, a relay goroutine, and a separate global `expireIdleFlows`
//! ticker — and neither the relay nor the ticker terminates on
//! shutdown, so Go's graceful drain always times out for UDP.
//!
//! Here each flow owns exactly one relay task with its own idle
//! deadline. The task removes its own flow from the map when it
//! exits (idle, error, or shutdown), so there is no shared-ticker
//! coordination and shutdown is clean: every task selects on the
//! shutdown signal and returns.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::net::{lookup_host, UdpSocket};
use tokio::sync::watch;
use tokio::time::sleep;
use tokio_util::task::TaskTracker;
use tracing::{error, info, warn};

use crate::forwarder::State;

/// One UDP flow: the connected destination socket plus the last
/// activity time used to compute the idle deadline.
struct UdpFlow {
    dst: Arc<UdpSocket>,
    last: Mutex<Instant>,
}

impl UdpFlow {
    fn new(dst: Arc<UdpSocket>) -> Self {
        Self {
            dst,
            last: Mutex::new(Instant::now()),
        }
    }
}

/// Read loop for one UDP forward. For each source address, creates a
/// connected socket to `dest_addr` and spawns a relay task that owns
/// the flow for its whole lifetime (idle expiry included).
pub(crate) async fn serve_udp(
    ln: Arc<UdpSocket>,
    dest_addr: String,
    idle_timeout: Duration,
    state: Arc<State>,
    tracker: TaskTracker,
    mut shutdown: watch::Receiver<bool>,
) {
    let dest = match lookup_host(&dest_addr).await {
        Ok(mut addrs) => match addrs.next() {
            Some(addr) => addr,
            None => {
                error!(dest_addr = %dest_addr, "resolve udp failed: no addresses");
                return;
            }
        },
        Err(err) => {
            error!(dest_addr = %dest_addr, err = %err, "resolve udp failed");
            return;
        }
    };

    let flows: Arc<Mutex<HashMap<std::net::SocketAddr, Arc<UdpFlow>>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let mut buf = vec![0u8; 65535];
    loop {
        let recv = tokio::select! {
            res = ln.recv_from(&mut buf) => res,
            _ = shutdown.wait_for(|v| *v) => break,
        };
        let (n, src) = match recv {
            Ok(pair) => pair,
            Err(err) => {
                warn!(err = %err, addr = %ln.local_addr().map(|a| a.to_string()).unwrap_or_default(), "read udp failed");
                return;
            }
        };

        let existing = {
            let guard = flows.lock().unwrap();
            guard.get(&src).cloned()
        };
        let flow = match existing {
            Some(flow) => {
                *flow.last.lock().unwrap() = Instant::now();
                flow
            }
            None => {
                let dc = match UdpSocket::bind("0.0.0.0:0").await {
                    Ok(dc) => Arc::new(dc),
                    Err(err) => {
                        error!(src = %src, err = %err, "bind udp flow failed");
                        continue;
                    }
                };
                if let Err(err) = dc.connect(dest).await {
                    error!(dest_addr = %dest_addr, err = %err, "dial udp failed");
                    continue;
                }
                state.inc_udp_flows();
                info!(src = %src, dest = %dest_addr, "udp flow opened");
                let flow = Arc::new(UdpFlow::new(dc));
                let task_flow = flow.clone();
                let ln = ln.clone();
                let state = state.clone();
                let task_flows = flows.clone();
                let mut shutdown = shutdown.clone();
                tracker.spawn(async move {
                    relay_udp_responses(
                        ln,
                        &task_flow,
                        src,
                        idle_timeout,
                        &task_flows,
                        &state,
                        &mut shutdown,
                    )
                    .await;
                });
                flows.lock().unwrap().insert(src, flow.clone());
                flow
            }
        };

        if let Err(err) = flow.dst.send(&buf[..n]).await {
            error!(src = %src, err = %err, "write udp failed");
        }
    }
}

/// Relay task owning one UDP flow. Reads responses from the
/// destination socket, writes them back to the source, and exits
/// when the flow goes idle (or on error / shutdown), removing its own
/// entry from `flows`.
async fn relay_udp_responses(
    ln: Arc<UdpSocket>,
    flow: &Arc<UdpFlow>,
    src: std::net::SocketAddr,
    idle_timeout: Duration,
    flows: &Arc<Mutex<HashMap<std::net::SocketAddr, Arc<UdpFlow>>>>,
    state: &Arc<State>,
    shutdown: &mut watch::Receiver<bool>,
) {
    let mut rbuf = vec![0u8; 65535];
    loop {
        let idle_remaining = {
            let last = *flow.last.lock().unwrap();
            idle_timeout.saturating_sub(last.elapsed())
        };
        let read = tokio::select! {
            res = flow.dst.recv(&mut rbuf) => res,
            _ = sleep(idle_remaining) => {
                info!(src = %src, "udp flow expired");
                break;
            }
            _ = shutdown.wait_for(|v| *v) => break,
        };
        let m = match read {
            Ok(n) => n,
            Err(err) => {
                info!(src = %src, err = %err, "udp flow relay exited");
                break;
            }
        };
        if let Err(err) = ln.send_to(&rbuf[..m], src).await {
            warn!(src = %src, err = %err, "udp relay write failed");
            break;
        }
        *flow.last.lock().unwrap() = Instant::now();
    }
    flows.lock().unwrap().remove(&src);
    state.dec_udp_flows();
}
