// SPDX-License-Identifier: AGPL-3.0-or-later
//! TCP forward serving: accept loop plus per-connection relay.
//!
//! Port of Go `internal/forwarder/tcp.go`. The accept loop breaks
//! when the shutdown signal fires (mirroring Go's context-based
//! cancellation), and each accepted connection is spawned through
//! the `TaskTracker` so graceful drain can wait for in-flight conns.

use std::sync::Arc;

use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio_util::task::TaskTracker;
use tracing::{error, info, warn};

use crate::forwarder::State;
/// Accept loop for one TCP forward. Runs until the shutdown signal
/// fires, then stops accepting. In-flight conns are tracked by
/// `tracker` so `run()` can drain them before exiting.
pub(crate) async fn serve_tcp(
    ln: TcpListener,
    dest_addr: String,
    state: Arc<State>,
    tracker: TaskTracker,
    mut shutdown: watch::Receiver<bool>,
) {
    loop {
        let accepted = tokio::select! {
            res = ln.accept() => res,
            _ = shutdown.wait_for(|v| *v) => break,
        };
        let (src, _) = match accepted {
            Ok(pair) => pair,
            Err(err) => {
                warn!(err = %err, addr = %ln.local_addr().map(|a| a.to_string()).unwrap_or_default(), "accept failed");
                return;
            }
        };
        state.inc_tcp_connections();
        let state = state.clone();
        let dest = dest_addr.clone();
        tracker.spawn(async move {
            handle_tcp_conn(src, &dest).await;
            state.dec_tcp_connections();
        });
    }
}

/// Relay one accepted connection to `dest_addr`, copying bytes in
/// both directions until either direction closes.
async fn handle_tcp_conn(src: TcpStream, dest_addr: &str) {
    let dst = match TcpStream::connect(dest_addr).await {
        Ok(conn) => conn,
        Err(err) => {
            error!(dest_addr = %dest_addr, err = %err, "dial tcp failed");
            return;
        }
    };
    info!(
        src = %src.peer_addr().map(|a| a.to_string()).unwrap_or_default(),
        dest = %dest_addr,
        "tcp connection opened"
    );
    let (mut src_r, mut src_w) = src.into_split();
    let (mut dst_r, mut dst_w) = dst.into_split();
    tokio::select! {
        r = tokio::io::copy(&mut src_r, &mut dst_w) => { drop(r); }
        r = tokio::io::copy(&mut dst_r, &mut src_w) => { drop(r); }
    }
    info!(
        src = %src_w.peer_addr().map(|a| a.to_string()).unwrap_or_default(),
        dest = %dest_addr,
        "tcp connection closed"
    );
}
