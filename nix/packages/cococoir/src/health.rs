// SPDX-License-Identifier: AGPL-3.0-or-later
//! Small HTTP `/healthz`, `/readyz`, and `/status` server.
//!
//! Port of Go `internal/health/server.go`. The forwarder calls
//! `HealthServer::new` with a status closure returning its current
//! `Stats` as a `serde_json::Value`; the health server serves that
//! value on `/status`. The health module does not import the
//! forwarder, so either side can evolve without coupling.
//!
//! Contract (pinned by the L2 `edge-forward` nixosTest):
//! - `/healthz` always 200 (`ok\n`) if the process is alive.
//! - `/readyz` 200 iff the status value has at least one
//!   `forwards[].bound == true`, else 503.
//! - `/status` returns the status value as pretty JSON.
//! - An empty addr disables the server: `run` returns immediately.

use std::sync::Arc;

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use tokio::net::TcpListener;
use tokio::sync::watch;
use thiserror::Error;
use tracing::info;

/// Returns the current state of the service as JSON. Called on every
/// `/readyz` and `/status` request. Must be cheap (a lock-free read
/// of in-memory state).
pub type StatusFunc = Arc<dyn Fn() -> serde_json::Value + Send + Sync>;

/// Health HTTP server. Construct with [`HealthServer::new`], drive
/// with [`HealthServer::run`].
pub struct HealthServer {
    addr: String,
    status_func: StatusFunc,
}

impl HealthServer {
    /// Returns a Server bound to `addr`. `status_func` is called on
    /// every `/readyz` and `/status` request. An empty `addr` means
    /// "disabled": `run` returns immediately.
    pub fn new(addr: String, status_func: StatusFunc) -> Self {
        Self { addr, status_func }
    }

    /// Builds the axum router for the three endpoints.
    fn router(&self) -> Router {
        Router::new()
            .route("/healthz", get(handle_healthz))
            .route("/readyz", get(handle_readyz))
            .route("/status", get(handle_status))
            .with_state(self.status_func.clone())
    }

    /// Binds `addr` and serves until the shutdown signal fires.
    /// Returns immediately (Ok) if `addr` was empty (server disabled).
    pub async fn run(
        self,
        mut shutdown: watch::Receiver<bool>,
    ) -> Result<(), HealthError> {
        if self.addr.is_empty() {
            info!("health server disabled (empty addr)");
            return Ok(());
        }
        let ln = TcpListener::bind(&self.addr)
            .await
            .map_err(|err| HealthError::Bind {
                addr: self.addr.clone(),
                source: err,
            })?;
        info!(addr = %self.addr, "health server listening");
        let router = self.router();
        axum::serve(ln, router)
            .with_graceful_shutdown(async move {
                let _ = shutdown.wait_for(|v| *v).await;
            })
            .await
            .map_err(|err| HealthError::Serve { source: err })
    }
}

/// Fatal error from [`HealthServer::run`].
#[derive(Debug, Error)]
pub enum HealthError {
    #[error("health: listen {addr}: {source}")]
    Bind {
        addr: String,
        #[source]
        source: std::io::Error,
    },
    #[error("health: serve: {source}")]
    Serve {
        #[source]
        source: std::io::Error,
    },
}

async fn handle_healthz() -> impl IntoResponse {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        "ok\n",
    )
}

async fn handle_readyz(State(status_func): State<StatusFunc>) -> impl IntoResponse {
    let status = status_func();
    let ready = ready_from_status(&status);
    let body = Json(serde_json::json!({ "ready": ready }));
    if ready {
        (StatusCode::OK, body)
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, body)
    }
}

async fn handle_status(State(status_func): State<StatusFunc>) -> impl IntoResponse {
    // Pretty-printed with 2-space indent to match the Go original's
    // `json.MarshalIndent(s.statusFunc(), "", "  ")`. The L2
    // edge-forward nixosTest asserts on the exact spaced JSON.
    let status = status_func();
    let body = serde_json::to_string_pretty(&status).unwrap_or_else(|_| "{}".to_string());
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/json")],
        body + "\n",
    )
}

/// True iff the status value has at least one `forwards[]` entry with
/// `bound == true`. Port of Go's `readyFromStatus`, which probes the
/// marshaled JSON so the health server stays independent of the
/// forwarder's Rust types.
fn ready_from_status(status: &serde_json::Value) -> bool {
    status
        .get("forwards")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|forwards| {
            forwards
                .iter()
                .any(|f| f.get("bound").and_then(serde_json::Value::as_bool) == Some(true))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    fn status_func_bound() -> StatusFunc {
        Arc::new(|| {
            serde_json::json!({
                "component": "cococoir-edge",
                "forwards": [{"bound": true, "listen_addr": "1.2.3.4:80"}]
            })
        })
    }

    fn status_func_unbound() -> StatusFunc {
        Arc::new(|| {
            serde_json::json!({
                "component": "cococoir-edge",
                "forwards": [{"bound": false, "last_error": "boom"}]
            })
        })
    }

    async fn get_body(router: Router, path: &str) -> (StatusCode, String) {
        let response = router
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (status, String::from_utf8(bytes.to_vec()).unwrap())
    }

    #[tokio::test]
    async fn healthz_is_always_ok() {
        let s = HealthServer::new("".to_string(), status_func_bound());
        let router = s.router();
        let (status, body) = get_body(router, "/healthz").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "ok\n");
    }

    #[tokio::test]
    async fn readyz_200_when_bound() {
        let s = HealthServer::new("".to_string(), status_func_bound());
        let router = s.router();
        let (status, body) = get_body(router, "/readyz").await;
        assert_eq!(status, StatusCode::OK);
        assert!(body.contains("\"ready\":true"));
    }

    #[tokio::test]
    async fn readyz_503_when_unbound() {
        let s = HealthServer::new("".to_string(), status_func_unbound());
        let router = s.router();
        let (status, body) = get_body(router, "/readyz").await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert!(body.contains("\"ready\":false"));
    }

    #[tokio::test]
    async fn status_returns_component_json() {
        let s = HealthServer::new("".to_string(), status_func_bound());
        let router = s.router();
        let (status, body) = get_body(router, "/status").await;
        assert_eq!(status, StatusCode::OK);
        assert!(body.contains("\"component\": \"cococoir-edge\""));
        assert!(body.contains("\"bound\": true"));
    }

    #[tokio::test]
    async fn readyz_rejects_non_get() {
        let s = HealthServer::new("".to_string(), status_func_bound());
        let router = s.router();
        let response = router
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/readyz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
    }

    #[tokio::test]
    async fn run_with_empty_addr_returns_immediately() {
        let (_, rx) = watch::channel(false);
        let s = HealthServer::new("".to_string(), status_func_bound());
        assert!(s.run(rx).await.is_ok());
    }
}
