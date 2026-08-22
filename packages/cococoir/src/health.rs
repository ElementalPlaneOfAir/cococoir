// SPDX-License-Identifier: AGPL-3.0-or-later
//! HTTP `/healthz`, `/readyz`, `/status` server + OpenAPI docs.
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
//!
//! The endpoints are `#[oai]` operations, so the OpenAPI v3 spec is
//! derived from the code itself ("compiles ⟹ spec-correct", no doc
//! rot). The spec is served at `/openapi.json` and a fully bundled
//! swagger UI at `/docs` (poem-openapi embeds JS/CSS via `include_str!`,
//! no CDN, so the box never needs network egress).

use std::sync::Arc;
use std::time::Duration;

use poem::listener::TcpAcceptor;
use poem::{Route, Server};
use poem_openapi::payload::{Json, PlainText};
use poem_openapi::{ApiResponse, Object, OpenApi, OpenApiService};
use thiserror::Error;
use tokio::sync::watch;
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

/// The `/readyz` response body.
#[derive(Object)]
struct ReadyBody {
    ready: bool,
}

/// `/readyz` is 200 once a forward is bound, else 503.
#[derive(ApiResponse)]
enum ReadyResponse {
    /// At least one forward is bound.
    #[oai(status = "200")]
    Ready(Json<ReadyBody>),
    /// No forward is bound yet.
    #[oai(status = "503")]
    NotReady(Json<ReadyBody>),
}

/// `/status` returns the raw status value as pretty JSON. The body is
/// built by hand (`to_string_pretty` + trailing newline) to keep the
/// byte-exact contract; `actual_type` documents the response honestly
/// as an arbitrary JSON object while leaving the runtime body alone.
#[derive(ApiResponse)]
enum StatusResponse {
    #[oai(status = "200", actual_type = "Json<serde_json::Value>")]
    Status(PlainText<String>),
}

/// The three endpoints, declared as OpenAPI operations.
struct HealthApi {
    status_func: StatusFunc,
}

#[OpenApi]
impl HealthApi {
    /// Liveness: 200 if the process is alive.
    #[oai(path = "/healthz", method = "get")]
    async fn healthz(&self) -> PlainText<&'static str> {
        PlainText("ok\n")
    }

    /// Readiness: 200 iff at least one forward is bound.
    #[oai(path = "/readyz", method = "get")]
    async fn readyz(&self) -> ReadyResponse {
        let ready = ready_from_status(&(self.status_func)());
        if ready {
            ReadyResponse::Ready(Json(ReadyBody { ready: true }))
        } else {
            ReadyResponse::NotReady(Json(ReadyBody { ready: false }))
        }
    }

    /// Full forwarder state as pretty JSON.
    #[oai(path = "/status", method = "get")]
    async fn status(&self) -> StatusResponse {
        // Pretty-printed with 2-space indent + trailing newline to match
        // the Go original's `json.MarshalIndent(s.statusFunc(), "", "  ")`.
        // The L2 edge-forward nixosTest asserts on the exact spaced JSON.
        let body = serde_json::to_string_pretty(&(self.status_func)())
            .unwrap_or_else(|_| "{}".to_string());
        StatusResponse::Status(PlainText(body + "\n"))
    }
}

impl HealthServer {
    /// Returns a Server bound to `addr`. `status_func` is called on
    /// every `/readyz` and `/status` request. An empty `addr` means
    /// "disabled": `run` returns immediately.
    pub fn new(addr: String, status_func: StatusFunc) -> Self {
        Self { addr, status_func }
    }

    /// Builds the poem route: the three health endpoints plus the
    /// OpenAPI spec and its bundled swagger UI.
    fn router(&self) -> Route {
        let api = HealthApi {
            status_func: self.status_func.clone(),
        };
        let service = OpenApiService::new(api, "cococoir", "0.1.0");
        let ui = service.swagger_ui();
        let spec = service.spec_endpoint();
        Route::new()
            .nest("/", service)
            .nest("/docs", ui)
            .nest("/openapi.json", spec)
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
        // Bind before serving so a busy addr surfaces as `Bind`, not `Serve`.
        let listener = tokio::net::TcpListener::bind(&self.addr)
            .await
            .map_err(|source| HealthError::Bind {
                addr: self.addr.clone(),
                source,
            })?;
        let acceptor = TcpAcceptor::from_tokio(listener).map_err(|source| {
            HealthError::Bind {
                addr: self.addr.clone(),
                source,
            }
        })?;
        let app = self.router();
        info!(addr = %self.addr, "health server listening");
        Server::new_with_acceptor(acceptor)
            .run_with_graceful_shutdown(
                app,
                async move {
                    let _ = shutdown.wait_for(|v| *v).await;
                },
                Some(Duration::from_secs(5)),
            )
            .await
            .map_err(|source| HealthError::Serve { source })
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
    use poem::http::StatusCode;
    use poem::test::TestClient;

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

    async fn get_body(router: Route, path: &str) -> (StatusCode, String) {
        let resp = TestClient::new(router).get(path).send().await;
        let status = resp.0.status();
        let body = resp.0.into_body().into_string().await.unwrap();
        (status, body)
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
        let resp = TestClient::new(router).post("/readyz").send().await;
        assert_eq!(resp.0.status(), StatusCode::METHOD_NOT_ALLOWED);
    }

    #[tokio::test]
    async fn run_with_empty_addr_returns_immediately() {
        let (_, rx) = watch::channel(false);
        let s = HealthServer::new("".to_string(), status_func_bound());
        assert!(s.run(rx).await.is_ok());
    }
}
