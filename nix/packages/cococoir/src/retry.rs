// SPDX-License-Identifier: AGPL-3.0-or-later
//! Retry-with-backoff for the initial bind, and the transient-error
//! classification that decides whether a failed bind is retryable.
//!
//! Port of Go `internal/forwarder/retry.go`. The Go `context.Context`
//! cancellation is replaced by a `watch::Receiver<bool>` shutdown
//! signal: when the sender flips the value (or is dropped), any
//! in-flight retry sleep is cut short and `BindError::Cancelled` is
//! returned — mirroring Go's `select { case <-time.After(delay):
//! case <-ctx.Done(): return ctx.Err() }`.

use std::io;
use std::time::{Duration, Instant};

use thiserror::Error;
use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::watch;
use tokio::time::sleep;

const RETRY_BACKOFF_START: Duration = Duration::from_millis(100);
const RETRY_BACKOFF_MAX: Duration = Duration::from_secs(5);

/// Bind failure that survived retry, or was never retryable.
#[derive(Debug, Error)]
pub enum BindError {
    #[error("listen {network} {addr}: {source}")]
    NonTransient {
        network: &'static str,
        addr: String,
        #[source]
        source: io::Error,
    },
    #[error("listen {network} {addr}: gave up after {timeout:?} ({attempts} attempts): {source}")]
    TimedOut {
        network: &'static str,
        addr: String,
        timeout: Duration,
        attempts: u32,
        #[source]
        source: io::Error,
    },
    #[error("bind cancelled before the address became available")]
    Cancelled,
}

/// Classifies a bind error as transient — worth retrying with
/// backoff until the deadline — matching Go's
/// `isTransientBindErr` (EADDRNOTAVAIL / ENETDOWN / ENETUNREACH).
fn is_transient_bind_err(e: &io::Error) -> bool {
    match e.kind() {
        io::ErrorKind::AddrNotAvailable => true,
        io::ErrorKind::NetworkDown => true,
        io::ErrorKind::NetworkUnreachable => true,
        _ => false,
    }
}

/// Next backoff delay: double, capped at `RETRY_BACKOFF_MAX`.
/// Port of Go `nextBackoff`.
fn next_backoff(d: Duration) -> Duration {
    let doubled = d * 2;
    if doubled > RETRY_BACKOFF_MAX {
        RETRY_BACKOFF_MAX
    } else {
        doubled
    }
}

/// TCP bind with retry-with-backoff. Resolves when the address
/// becomes bindable (e.g. a per-IP address that has not appeared on
/// the local interface yet), gives up at `timeout`, or cancels when
/// the shutdown signal fires.
pub async fn retry_bind_tcp(
    addr: &str,
    timeout: Duration,
    shutdown: watch::Receiver<bool>,
) -> Result<TcpListener, BindError> {
    retry_with_backoff(|| TcpListener::bind(addr), "tcp", addr, timeout, shutdown).await
}

/// UDP bind with retry-with-backoff. Same contract as
/// [`retry_bind_tcp`] for the packet path.
pub async fn retry_bind_udp(
    addr: &str,
    timeout: Duration,
    shutdown: watch::Receiver<bool>,
) -> Result<UdpSocket, BindError> {
    retry_with_backoff(|| UdpSocket::bind(addr), "udp", addr, timeout, shutdown).await
}

/// Shared retry loop for both protocols. The `bind` closure runs the
/// (async) bind; on a transient failure we sleep with backoff unless
/// the shutdown signal fires first.
async fn retry_with_backoff<T, F, Fut>(
    mut bind: F,
    network: &'static str,
    addr: &str,
    timeout: Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<T, BindError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = io::Result<T>>,
{
    let deadline = Instant::now() + timeout;
    let mut delay = RETRY_BACKOFF_START;
    let mut attempts: u32 = 0;
    loop {
        attempts += 1;
        match bind().await {
            Ok(value) => return Ok(value),
            Err(err) => {
                if !is_transient_bind_err(&err) {
                    return Err(BindError::NonTransient {
                        network,
                        addr: addr.to_string(),
                        source: err,
                    });
                }
                if Instant::now() >= deadline {
                    return Err(BindError::TimedOut {
                        network,
                        addr: addr.to_string(),
                        timeout,
                        attempts,
                        source: err,
                    });
                }
                tokio::select! {
                    _ = sleep(delay) => {}
                    _ = shutdown.changed() => {
                        return Err(BindError::Cancelled);
                    }
                }
                delay = next_backoff(delay);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn errno(e: &io::Error) -> Option<i32> {
        e.raw_os_error()
    }

    #[test]
    fn transient_bind_err_classification() {
        use std::io::ErrorKind;
        assert!(!is_transient_bind_err(&io::Error::new(ErrorKind::NotFound, "x")));
        assert!(is_transient_bind_err(&io::Error::from_raw_os_error(99)));
        assert!(is_transient_bind_err(&io::Error::from_raw_os_error(100)));
        assert!(is_transient_bind_err(&io::Error::from_raw_os_error(101)));
    }

    #[test]
    fn errno_round_trip() {
        let e = io::Error::from_raw_os_error(99);
        assert_eq!(errno(&e), Some(99));
    }

    #[test]
    fn next_backoff_doubles() {
        assert_eq!(next_backoff(RETRY_BACKOFF_START), Duration::from_millis(200));
    }

    #[test]
    fn next_backoff_caps_at_max() {
        assert_eq!(next_backoff(RETRY_BACKOFF_MAX), RETRY_BACKOFF_MAX);
        assert_eq!(next_backoff(RETRY_BACKOFF_MAX * 2), RETRY_BACKOFF_MAX);
    }

    #[tokio::test]
    async fn bind_succeeds_immediately() {
        let (_tx, rx) = watch::channel(false);
        let ln = retry_bind_tcp("127.0.0.1:0", Duration::from_secs(1), rx)
            .await
            .unwrap();
        assert!(ln.local_addr().unwrap().port() > 0);
    }

    #[tokio::test]
    async fn bind_succeeds_after_transient_failure() {
        let (_tx, rx) = watch::channel(false);
        // Bind twice to the same ephemeral-free address: the second
        // bind fails with AddrInUse (non-transient). Instead, claim a
        // port on a loopback, close it, and bind again — always
        // transient-free. This test exercises the retry path via the
        // address family: bind "127.0.0.1:0" repeatedly through a
        // closure that fails the first N calls with a transient error.
        let mut calls = 0;
        let ln = retry_with_backoff::<TcpListener, _, _>(
            || {
                calls += 1;
                let n = calls;
                async move {
                    if n < 3 {
                        Err(io::Error::from_raw_os_error(99))
                    } else {
                        TcpListener::bind("127.0.0.1:0").await
                    }
                }
            },
            "tcp",
            "127.0.0.1:0",
            Duration::from_secs(2),
            rx,
        )
        .await
        .unwrap();
        assert!(ln.local_addr().unwrap().port() > 0);
        assert_eq!(calls, 3);
    }

    #[tokio::test]
    async fn bind_gives_up_after_timeout() {
        let (_tx, rx) = watch::channel(false);
        let err = retry_with_backoff::<TcpListener, _, _>(
            || async { Err(io::Error::from_raw_os_error(99)) },
            "tcp",
            "192.0.2.1:80",
            Duration::from_millis(300),
            rx,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindError::TimedOut { .. }));
    }

    #[tokio::test]
    async fn bind_cancels_on_shutdown() {
        let (tx, rx) = watch::channel(false);
        let fut = retry_with_backoff::<TcpListener, _, _>(
            || async { Err(io::Error::from_raw_os_error(99)) },
            "tcp",
            "192.0.2.1:80",
            Duration::from_secs(30),
            rx,
        );
        let handle = tokio::spawn(fut);
        tokio::time::sleep(Duration::from_millis(150)).await;
        tx.send(true).unwrap();
        let err = handle.await.unwrap().unwrap_err();
        assert!(matches!(err, BindError::Cancelled));
    }
}
