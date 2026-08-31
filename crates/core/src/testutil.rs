// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Test-only: serializes tests that bind real sockets. The kernel can
// hand the same ephemeral port to two parallel `bind(127.0.0.1:0)`
// calls once the first socket is released. `pick_free_*` in the
// forwarder probes a port, releases the probe, then re-binds it later
// — a sibling test can grab the port in between and the re-bind dies
// with AddrInUse. Every test that binds a socket holds this guard for
// its whole body so a released port cannot be re-handed out before the
// owning test re-binds it.
use std::sync::OnceLock;
use tokio::sync::Mutex;
use tokio::sync::MutexGuard;

static REAL_SOCKET_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

pub(crate) async fn lock_real_sockets() -> MutexGuard<'static, ()> {
    REAL_SOCKET_TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .await
}