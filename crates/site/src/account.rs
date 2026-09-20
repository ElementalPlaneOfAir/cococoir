//! The account lifecycle server functions — the dioxus fullstack
//! bridge between the auth pages and the embedded ControlPlane.
//!
//! These are the replacement for the controlplane's poem `/auth/*`
//! form handlers. Unlike the poem surface (form POST → server
//! re-renders HTML), the fullstack ergonomics are: the dioxus
//! components hold form state, call these typed server functions, and
//! re-render from the typed outcome — no form round-trip, no partial
//! page. The session cookie is set on the response by
//! [`login`] via `FullstackContext::add_response_header`.
//!
//! The server-fn bodies are `#[cfg(feature = "server")]`-gated by the
//! `#[server]` macro, so the wasm client tier never compiles the
//! embedded controlplane. The DTOs below are the serializable contract
//! both tiers share.

use dioxus::prelude::*;
#[cfg(feature = "server")]
use dioxus::prelude::dioxus_fullstack::http::HeaderMap;
use serde::{Deserialize, Serialize};

/// Outcome of a signup attempt. The account is `pending` until the
/// emailed link is used.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum SignupOutcome {
    /// Account created; a verification link was emailed. The UI shows
    /// "check your email".
    Created,
    /// Signup failed; `message` is customer-facing.
    Error { message: String },
}

/// Outcome of a login attempt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum LoginOutcome {
    /// Session established; the `fortress_account_session` cookie was
    /// set on the response.
    Ok,
    /// The account is real but not yet verified.
    NeedsVerification { email: String },
    /// Login failed; `message` is customer-facing.
    Error { message: String },
}

/// Whether the current request carries a live account session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum SessionState {
    Anonymous,
    LoggedIn { email: String },
}

/// Outcome of a verification-link click. The verify *page* is T2b;
/// the server function exists now because the account lifecycle
/// round-trip (signup → verify → login) needs it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum VerifyOutcome {
    /// The token was single-use consumed; the account is now active.
    Activated,
    /// The link is invalid or already used.
    Invalid,
}

/// Resolve the current session from the request cookie. A missing
/// backend (SSR-only tests) or absent cookie resolves to `Anonymous` —
/// this is the read-only surface the landing renders through, so it
/// must never fail the page.
#[server(endpoint = "auth/session", headers: HeaderMap)]
pub async fn current_session() -> Result<SessionState, ServerFnError> {
    let Some(token) = crate::server::read_session_cookie(&headers) else {
        return Ok(SessionState::Anonymous);
    };
    let Ok(backend) = crate::server::backend() else {
        return Ok(SessionState::Anonymous);
    };
    match backend.cp.session_account(&token).await {
        Ok(Some(email)) => Ok(SessionState::LoggedIn { email }),
        _ => Ok(SessionState::Anonymous),
    }
}

/// Create a pending account. The ControlPlane emails a single-use
/// verification link; the UI then shows "check your email".
#[server(endpoint = "auth/signup")]
pub async fn signup(email: String, password: String) -> Result<SignupOutcome, ServerFnError> {
    let backend = crate::server::backend()?;
    match backend
        .cp
        .account_signup(&email, &password, backend.mailer)
        .await
    {
        Ok(()) => Ok(SignupOutcome::Created),
        Err(err) => Ok(SignupOutcome::Error {
            message: fortress_controlplane::account_error_message(&err),
        }),
    }
}

/// Consume a verification link. Idempotent-ish: an invalid or already
/// used token is `Invalid` (a single-use GETDEL burns it either way).
#[server(endpoint = "auth/verify")]
pub async fn verify(token: String) -> Result<VerifyOutcome, ServerFnError> {
    let backend = crate::server::backend()?;
    match backend.cp.account_verify(&token).await {
        Ok(()) => Ok(VerifyOutcome::Activated),
        Err(_) => Ok(VerifyOutcome::Invalid),
    }
}

/// Log in: verify the credentials, open a session, and set the HttpOnly
/// session cookie on the response. Unverified accounts are told the
/// truth (enumeration is already possible via signup's duplicate-email
/// error, so silence buys nothing — see `ResetOutcome` in the
/// controlplane).
#[server(endpoint = "auth/login")]
pub async fn login(email: String, password: String) -> Result<LoginOutcome, ServerFnError> {
    use fortress_controlplane::controlplane::account::AccountError;
    let backend = crate::server::backend()?;
    match backend.cp.account_login(&email, &password).await {
        Ok(token) => {
            crate::server::set_session_cookie(&token)?;
            Ok(LoginOutcome::Ok)
        }
        Err(AccountError::NotVerified(email)) => Ok(LoginOutcome::NeedsVerification { email }),
        Err(err) => Ok(LoginOutcome::Error {
            message: fortress_controlplane::account_error_message(&err),
        }),
    }
}

/// Invalidate the current session and clear the session cookie.
#[server(endpoint = "auth/logout", headers: HeaderMap)]
pub async fn logout() -> Result<(), ServerFnError> {
    let backend = crate::server::backend()?;
    if let Some(token) = crate::server::read_session_cookie(&headers) {
        let _ = backend.cp.account_logout(&token).await;
    }
    crate::server::clear_session_cookie()?;
    Ok(())
}