//! The `/api/*` machine contract on axum + utoipa.
//!
//! The client-facing paths dialed by `crates/client/src/pairing.rs` must
//! survive **byte-for-byte**:
//!   POST /api/invites/{code}/begin    {"public_key"}
//!   GET  /api/invites/{code}/poll     {"status","machine":{"wg_ip"},"deviceToken"}
//!   GET  /api/wireguard/pubkey        {"public_key"}
//!   POST /api/device/register         {"device_token","public_key"}
//!
//! Key styles are deliberately mixed (snake in, camel out) — that IS the
//! contract and must not be tidied up. `pairing_wire_shapes_hold` is the
//! tripwire.
//!
//! These handlers ARE the controlplane domain (T5): each one delegates
//! to a `ControlPlane` method and maps the outcome into the wire shape
//! above. The domain's own `PollOutcome` cannot be returned directly —
//! its `device_token` field serde-serializes snake and it leaks the full
//! `Machine` record — so the mapping here is the byte-for-byte gate.

use axum::{
    Json, Router as AxumRouter,
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use utoipa::OpenApi;

use crate::SiteBackend;

use fortress_controlplane::controlplane::pairing::InviteError;
use fortress_controlplane::ControlPlaneError;

#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct BeginBody {
    pub public_key: String,
}

#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct RegisterBody {
    pub device_token: String,
    pub public_key: String,
}

#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct MachineInfo {
    pub wg_ip: String,
}

#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct PollOutcome {
    pub status: String,
    /// Present only on the one approved delivery.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<MachineInfo>,
    /// Same one-time rule as `machine`. Camel on the wire — that is the
    /// contract (`pairing.rs` reads `deviceToken`).
    #[serde(rename = "deviceToken", skip_serializing_if = "Option::is_none")]
    pub device_token: Option<String>,
}

#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct PubkeyOut {
    pub public_key: String,
}

/// The error surface: a status code plus a short machine-facing message
/// (never a credential, never the full domain error).
pub struct ApiError(StatusCode, String);

impl ApiError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self(status, message.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (self.0, Json(self.1)).into_response()
    }
}

/// Map an [`InviteError`] onto its status code, mirroring the domain's
/// own HTTP surface (`InviteError::Forbidden` stays 403 — wrong owner).
fn invite_status(err: &InviteError) -> StatusCode {
    match err {
        InviteError::InvalidCode(_) => StatusCode::BAD_REQUEST,
        InviteError::Unknown(_) => StatusCode::NOT_FOUND,
        InviteError::Forbidden(_) => StatusCode::FORBIDDEN,
        InviteError::NotWaiting(_) | InviteError::NameTaken(_) => StatusCode::CONFLICT,
        InviteError::InvalidName(_) | InviteError::InvalidPubkey(_) => StatusCode::BAD_REQUEST,
        InviteError::Account(_) | InviteError::Corrupt(_) | InviteError::Redis(_) => {
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

impl From<InviteError> for ApiError {
    fn from(err: InviteError) -> Self {
        let message = match &err {
            InviteError::InvalidCode(_) => "invalid invite code",
            InviteError::Unknown(_) => "invite not found",
            InviteError::Forbidden(_) => "not the inviting account",
            InviteError::NotWaiting(_) => "invite is not in a claimable state",
            InviteError::NameTaken(name) => {
                return ApiError::new(StatusCode::CONFLICT, format!("machine name {name} is already taken"));
            }
            InviteError::InvalidName(_) => "invalid machine name",
            InviteError::InvalidPubkey(_) => "invalid wireguard public key",
            InviteError::Account(_) | InviteError::Corrupt(_) | InviteError::Redis(_) => {
                "internal error"
            }
        };
        ApiError::new(invite_status(&err), message)
    }
}

impl From<ControlPlaneError> for ApiError {
    fn from(err: ControlPlaneError) -> Self {
        let (status, message) = match err {
            ControlPlaneError::NotFound(_) => {
                (StatusCode::UNAUTHORIZED, "invalid device token".to_string())
            }
            ControlPlaneError::InvalidPubkey(_) => {
                (StatusCode::BAD_REQUEST, "invalid wireguard public key".to_string())
            }
            err => {
                tracing::error!(error = %err, "api: internal control plane error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        ApiError::new(status, message)
    }
}

/// Map the domain outcome onto the wire shape. Only `wg_ip` crosses the
/// wire from the machine record; the domain's own `PollOutcome` (snake
/// `device_token`, full `Machine`) must not.
fn map_poll(outcome: fortress_controlplane::controlplane::pairing::PollOutcome) -> PollOutcome {
    PollOutcome {
        status: outcome.status,
        machine: outcome.machine.map(|machine| MachineInfo {
            wg_ip: machine.wg_ip,
        }),
        device_token: outcome.device_token,
    }
}

#[utoipa::path(
    post,
    path = "/api/invites/{code}/begin",
    request_body = BeginBody,
    responses((status = 200, body = PollOutcome))
)]
pub async fn invite_begin(
    State(backend): State<&'static SiteBackend>,
    Path(code): Path<String>,
    Json(body): Json<BeginBody>,
) -> Result<Json<PollOutcome>, ApiError> {
    let outcome = backend.cp.invite_begin(&code, &body.public_key).await?;
    Ok(Json(map_poll(outcome)))
}

#[utoipa::path(
    get,
    path = "/api/invites/{code}/poll",
    responses((status = 200, body = PollOutcome))
)]
pub async fn invite_poll(
    State(backend): State<&'static SiteBackend>,
    Path(code): Path<String>,
) -> Result<Json<PollOutcome>, ApiError> {
    let outcome = backend.cp.invite_poll(&code).await?;
    Ok(Json(map_poll(outcome)))
}

#[utoipa::path(
    get,
    path = "/api/wireguard/pubkey",
    responses((status = 200, body = PubkeyOut))
)]
pub async fn wireguard_pubkey(
    State(backend): State<&'static SiteBackend>,
) -> Result<Json<PubkeyOut>, ApiError> {
    let public_key = backend.cp.edge_public_key()?;
    Ok(Json(PubkeyOut { public_key }))
}

#[utoipa::path(
    post,
    path = "/api/device/register",
    request_body = RegisterBody,
    responses((status = 204))
)]
pub async fn device_register(
    State(backend): State<&'static SiteBackend>,
    Json(body): Json<RegisterBody>,
) -> Result<StatusCode, ApiError> {
    backend.cp.device_register(&body.device_token, &body.public_key).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(OpenApi)]
#[openapi(paths(invite_begin, invite_poll, wireguard_pubkey, device_register))]
pub struct ApiDoc;

/// The `/api/*` tree, declared with full `/api/...` paths and merged at
/// the root (see `server.rs` for why `nest` is forbidden here). The
/// backend is held as axum state so the handlers reach the control
/// plane.
pub fn router(backend: &'static SiteBackend) -> AxumRouter {
    AxumRouter::new()
        .route("/api/invites/{code}/begin", post(invite_begin))
        .route("/api/invites/{code}/poll", get(invite_poll))
        .route("/api/wireguard/pubkey", get(wireguard_pubkey))
        .route("/api/device/register", post(device_register))
        .route("/api/openapi.json", get(|| async { Json(ApiDoc::openapi()) }))
        .with_state(backend)
}

#[cfg(test)]
mod wire_mapping_tests {
    use super::*;

    /// `map_poll` is the seam that turns a domain `PollOutcome` (snake
    /// `device_token`, full `Machine`) into the wire the box's
    /// `pairing.rs` parser reads. This feeds a REAL domain outcome
    /// through the mapping and asserts the exact keys the client dials:
    /// top-level `status`, nested `machine.wg_ip`, camel `deviceToken`.
    #[test]
    fn map_poll_produces_the_pairing_wire_shape() {
        use fortress_controlplane::Machine;

        let domain = fortress_controlplane::controlplane::pairing::PollOutcome {
            status: "approved".into(),
            machine: Some(Machine {
                name: "mainbox".into(),
                owner: Some("uuid".into()),
                hostname: "mainbox.example.net".into(),
                ipv6: "2a01:4f8:c17:1::2".into(),
                wg_ip: "10.10.0.2".into(),
                wg_public_key: "pk".into(),
                device_token_hash: Some("sha256hex".into()),
            }),
            device_token: Some("64chars".into()),
        };

        let wire = serde_json::to_value(map_poll(domain)).expect("maps");
        assert_eq!(
            wire.get("status").and_then(|v| v.as_str()),
            Some("approved"),
            "top-level status survives: {wire}"
        );
        assert_eq!(
            wire.pointer("/machine/wg_ip").and_then(|v| v.as_str()),
            Some("10.10.0.2"),
            "machine.wg_ip is the ONLY machine field on the wire: {wire}"
        );
        assert_eq!(
            wire.get("deviceToken").and_then(|v| v.as_str()),
            Some("64chars"),
            "deviceToken is camel on the wire — the client reads deviceToken, not device_token: {wire}"
        );
        // The rest of the Machine record must NOT leak to the machine.
        for leaked in ["device_token_hash", "hostname", "wg_public_key", "owner", "ipv6"] {
            assert!(
                wire.get(leaked).is_none(),
                "machine field '{leaked}' must not cross the wire: {wire}"
            );
            assert!(
                wire.pointer(&format!("/machine/{leaked}")).is_none(),
                "machine field '{leaked}' must not leak under /machine: {wire}"
            );
        }
    }

    /// Waiting/denied outcomes carry no machine and no token — the keys
    /// are absent, not null (the client's parser reads absent as None).
    #[test]
    fn map_poll_omits_machine_and_token_when_absent() {
        let domain = fortress_controlplane::controlplane::pairing::PollOutcome {
            status: "waiting".into(),
            machine: None,
            device_token: None,
        };
        let wire = serde_json::to_value(map_poll(domain)).expect("maps");
        assert!(wire.get("machine").is_none(), "no machine key when absent: {wire}");
        assert!(
            wire.get("deviceToken").is_none(),
            "no deviceToken key when absent: {wire}"
        );
        assert_eq!(wire.get("status").and_then(|v| v.as_str()), Some("waiting"));
    }
}

/// Store-backed proof that the COMPOSED router (`server::app`) runs a
/// full enrollment exactly as `crates/client/src/pairing.rs` dials it:
/// begin → owner approves → poll delivers the tunnel config + token in
/// the byte-for-byte wire shape. Gated on `REDIS_URL` like the
/// controlplane's own store-backed tests.
#[cfg(test)]
mod enrollment_e2e_tests {
    use super::*;
    use axum::body::Body;
    use fortress_controlplane::controlplane::mail::MockMailer;
    use fortress_controlplane::{
        controlplane::{dns::MockDnsApiClient, wg::MockWgClient},
        ControlPlane,
    };
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn test_backend() -> Option<(&'static SiteBackend, &'static MockMailer)> {
        let url = std::env::var("REDIS_URL").ok().filter(|u| !u.is_empty())?;
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = fortress_controlplane::Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = fortress_controlplane::WgSubnet::from_str("10.10.0.0/24").unwrap();
        let cp = ControlPlane::with_deps(
            &url,
            subnet,
            wg_subnet,
            "example.net",
            fortress_controlplane::DUMMY_EDGE_WG_PRIV,
            wg,
            dns,
        )
        .ok()?;
        // The backend's mailer is only ever used by the web auth pages,
        // never by the `/api` handlers under test — a console mailer is
        // enough. The MockMailer is captured separately for
        // `active_account`, which drives the signup/verify flow directly.
        let mailer: &'static MockMailer = Box::leak(Box::new(MockMailer::new()));
        let backend = Box::leak(Box::new(SiteBackend {
            cp,
            mailer: Box::new(fortress_controlplane::controlplane::mail::ConsoleMailer),
        }));
        Some((backend, mailer))
    }

    fn unique_email(label: &str) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{label}-{}-{}@example.com", std::process::id(), nanos)
    }

    fn wg_pubkey() -> String {
        fortress_controlplane::generate_wg_keypair().0
    }

    /// Create an account via the domain and consume the emailed verify
    /// link so it becomes active — the same path the web UI drives.
    /// Returns the verify token extracted from the magic link.
    async fn active_account(
        cp: &ControlPlane,
        mailer: &MockMailer,
        email: &str,
    ) -> String {
        cp.account_signup(email, "hunter2", mailer)
            .await
            .expect("signup");
        let sent = mailer.sent();
        let body = sent
            .iter()
            .find(|m| m.to == email)
            .map(|m| m.body.clone())
            .expect("a verification mail went to the new account");
        let token = body
            .split("verify?token=")
            .nth(1)
            .and_then(|rest| rest.split_whitespace().next())
            .map(str::to_string)
            .expect("magic link carries the token");
        cp.account_verify(&token).await.expect("verify");
        token
    }

    async fn post_json(
        app: &axum::Router,
        uri: &str,
        body: &str,
    ) -> (axum::http::StatusCode, String) {
        let res = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri(uri)
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

    async fn get_json(app: &axum::Router, uri: &str) -> (axum::http::StatusCode, String) {
        let res = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("GET")
                    .uri(uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

    /// The full enrollment round trip through the composed router:
    /// exactly the calls `pairing.rs` makes, asserting the wire shape
    /// `pairing.rs::poll_outcome` parses (status / machine.wg_ip /
    /// deviceToken).
    #[tokio::test]
    async fn full_enrollment_round_trip_through_the_composed_router() {
        let Some((backend, mailer)) = test_backend() else {
            eprintln!("skipping: REDIS_URL not set");
            return;
        };
        // Approving an invite calls `allocate_machine`, which mutates
        // the process-global forwarder — seed the same singleton the
        // controlplane's own store-backed tests use.
        fortress_controlplane::controlplane::set_forwarder_for_tests();
        // Clean the name this test owns so a previous/aborted run
        // doesn't make it fail on a name clash.
        let _ = backend.cp.delete("siteteam").await;

        let email = unique_email("site-e2e");
        active_account(&backend.cp, mailer, &email).await;
        let code = backend.cp.invite_create(&email).await.expect("create invite");

        let app = crate::server::app(backend);

        // The machine begins with its pubkey.
        let pk = wg_pubkey();
        let (status, body) = post_json(&app, &format!("/api/invites/{code}/begin"), &format!(
            r#"{{"public_key":"{pk}"}}"#
        ))
        .await;
        assert_eq!(status, 200, "begin: {body}");
        let begun: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(begun["status"], "waiting");

        // Poll before approval: waiting, no machine, no token.
        let (status, body) = get_json(&app, &format!("/api/invites/{code}/poll")).await;
        assert_eq!(status, 200, "poll waiting: {body}");
        let polled: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(polled["status"], "waiting");
        assert!(polled.get("machine").is_none());
        assert!(polled.get("deviceToken").is_none());

        // The owner approves via the domain (the dashboard's own action,
        // not on the wire here).
        backend
            .cp
            .invite_approve(&email, &code, "siteteam")
            .await
            .expect("approve");

        // The machine's next poll delivers the tunnel config + token.
        let (status, body) = get_json(&app, &format!("/api/invites/{code}/poll")).await;
        assert_eq!(status, 200, "poll approved: {body}");
        let approved: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(approved["status"], "approved");
        // This is the shape `pairing.rs::poll_outcome` reads.
        assert_eq!(
            approved.pointer("/machine/wg_ip").and_then(|v| v.as_str()),
            Some("10.10.0.2"),
            "machine.wg_ip present + correct: {approved}"
        );
        let token = approved["deviceToken"].as_str().expect("deviceToken camel");
        assert_eq!(token.len(), 64, "32-byte hex token");

        // One-time delivery: a second poll has no payload.
        let (status, body) = get_json(&app, &format!("/api/invites/{code}/poll")).await;
        assert_eq!(status, 200, "poll consumed: {body}");
        let consumed: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert!(consumed.get("machine").is_none());
        assert!(consumed.get("deviceToken").is_none());

        // Rotation via /api/device/register (the box's `rotate`): the
        // token is the credential, the route is kept.
        let rotated_pk = wg_pubkey();
        let (status, body) = post_json(&app, "/api/device/register", &format!(
            r#"{{"device_token":"{token}","public_key":"{rotated_pk}"}}"#
        ))
        .await;
        assert_eq!(status, 204, "register: {body}");

        // A wrong token is rejected (401), not a leaky 404.
        let (status, body) = post_json(&app, "/api/device/register", &format!(
            r#"{{"device_token":"wrong","public_key":"{rotated_pk}"}}"#
        ))
        .await;
        assert_eq!(status, 401, "register wrong token: {body}");
    }
}