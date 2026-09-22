//! The account lifecycle bridge between the auth pages and the
//! embedded [`SiteBackend`].
//!
//! Plain async functions over the controlplane's domain methods — no
//! request-layer coupling. The topcoat pages call these and turn the
//! typed outcomes into Post/Redirect/Get responses.
//!
//! The session cookie is the controlplane's (`fortress_account_session`,
//! HttpOnly) — set on the redirect response on login, cleared on logout.
//! This crate deliberately does NOT adopt `topcoat-session`: the session
//! store (`fortress:session:*`) and cookie name are load-bearing for the
//! existing controlplane and `pairing.rs` tests.

use fortress_controlplane::controlplane::account::AccountError;
use fortress_controlplane::controlplane::web::{
    clear_session_cookie_header, read_cookie_from_headers, session_cookie_header,
};
use topcoat::router::{HeaderMap, HeaderValue};

pub use fortress_controlplane::controlplane::web::SESSION_COOKIE;

use crate::SiteBackend;

/// Outcome of a signup attempt. The account is `pending` until the
/// emailed link is used.
#[derive(Debug, Clone, PartialEq)]
pub enum SignupOutcome {
    /// Account created; a verification link was emailed.
    Created,
    /// Signup failed; `code` is a short PRG query token, never a secret.
    Error { code: &'static str },
}

/// Outcome of a login attempt.
#[derive(Debug, Clone, PartialEq)]
pub enum LoginOutcome {
    /// Session established; the caller sets this Set-Cookie header on
    /// its redirect response.
    Ok { cookie: HeaderValue },
    /// The account is real but not yet verified.
    NeedsVerification,
    /// Login failed.
    Error { code: &'static str },
}

/// Whether the current request carries a live account session.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionState {
    Anonymous,
    LoggedIn { email: String },
}

/// Outcome of consuming a verification link.
#[derive(Debug, Clone, PartialEq)]
pub enum VerifyOutcome {
    Activated,
    Invalid,
}

/// Outcome of a password-reset request.
#[derive(Debug, Clone, PartialEq)]
pub enum ForgotOutcome {
    Sent,
    UnknownEmail,
    Error { code: &'static str },
}

/// Outcome of consuming a reset link.
#[derive(Debug, Clone, PartialEq)]
pub enum ResetOutcome {
    Done,
    Invalid,
}

/// Outcome of resending a verification link.
#[derive(Debug, Clone, PartialEq)]
pub enum ResendOutcome {
    Sent,
    AlreadyActive,
    UnknownEmail,
}

/// Map an [`AccountError`] onto a short PRG token. Signup already leaks
/// registration status by design (the duplicate-email error is
/// user-visible), so hiding the same fact on the reset path bought
/// nothing — see the controlplane's `ResetOutcome`.
pub fn error_code(err: &AccountError) -> &'static str {
    match err {
        AccountError::NotVerified(_) => "needs_verify",
        AccountError::DuplicateEmail(_) => "exists",
        AccountError::NotFound => "unknown",
        AccountError::InvalidCredentials => "bad_credentials",
        AccountError::InvalidToken => "invalid_token",
        AccountError::Mail(_) => "mail_failed",
        AccountError::InvalidEmail(_)
        | AccountError::InvalidPassword(_)
        | AccountError::Corrupt(_)
        | AccountError::Redis(_) => "failed",
    }
}

/// Resolve the current session from the request cookie. A missing or
/// stale cookie resolves to `Anonymous` — this is the read-only surface
/// the landing renders through, so it must never fail the page.
pub async fn current_session(backend: &SiteBackend, headers: &HeaderMap) -> SessionState {
    let Some(token) = read_cookie_from_headers(headers, SESSION_COOKIE) else {
        return SessionState::Anonymous;
    };
    match backend.cp.session_account(&token).await {
        Ok(Some(email)) => SessionState::LoggedIn { email },
        _ => SessionState::Anonymous,
    }
}

/// Create a pending account and email a single-use verification link.
pub async fn signup(backend: &SiteBackend, email: &str, password: &str) -> SignupOutcome {
    match backend
        .cp
        .account_signup(email, password, backend.mailer.as_ref())
        .await
    {
        Ok(()) => SignupOutcome::Created,
        Err(err) => SignupOutcome::Error {
            code: error_code(&err),
        },
    }
}

/// Consume a verification link. Single-use (GETDEL) either way, so an
/// invalid token and an already-used one are both [`VerifyOutcome::Invalid`].
pub async fn verify(backend: &SiteBackend, token: &str) -> VerifyOutcome {
    match backend.cp.account_verify(token).await {
        Ok(()) => VerifyOutcome::Activated,
        Err(_) => VerifyOutcome::Invalid,
    }
}

/// Log in: verify credentials, open a session, and produce the Set-Cookie
/// header for the caller to put on its redirect response.
pub async fn login(backend: &SiteBackend, email: &str, password: &str) -> LoginOutcome {
    match backend.cp.account_login(email, password).await {
        Ok(token) => LoginOutcome::Ok {
            cookie: session_cookie_header(&token),
        },
        Err(AccountError::NotVerified(_)) => LoginOutcome::NeedsVerification,
        Err(err) => LoginOutcome::Error {
            code: error_code(&err),
        },
    }
}

/// Invalidate the current session server-side. Best-effort: the cookie
/// clear is the security-relevant half, and a store failure must not
/// leave the user stuck signed in at the browser.
pub async fn logout(backend: &SiteBackend, headers: &HeaderMap) -> HeaderValue {
    if let Some(token) = read_cookie_from_headers(headers, SESSION_COOKIE) {
        let _ = backend.cp.account_logout(&token).await;
    }
    clear_session_cookie_header()
}

/// Request a password-reset email.
pub async fn forgot(backend: &SiteBackend, email: &str) -> ForgotOutcome {
    use fortress_controlplane::controlplane::account::ResetOutcome;
    match backend
        .cp
        .request_password_reset(email, backend.mailer.as_ref())
        .await
    {
        Ok(ResetOutcome::Sent) => ForgotOutcome::Sent,
        Ok(ResetOutcome::UnknownEmail) => ForgotOutcome::UnknownEmail,
        Err(err) => ForgotOutcome::Error {
            code: error_code(&err),
        },
    }
}

/// Consume a reset link and set the new password.
pub async fn reset(backend: &SiteBackend, token: &str, password: &str) -> ResetOutcome {
    match backend.cp.reset_password(token, password).await {
        Ok(()) => ResetOutcome::Done,
        Err(_) => ResetOutcome::Invalid,
    }
}

/// Resend a verification link for a still-pending account.
pub async fn resend(backend: &SiteBackend, email: &str) -> ResendOutcome {
    use fortress_controlplane::controlplane::account::ResendVerifyOutcome;
    match backend
        .cp
        .resend_verification(email, backend.mailer.as_ref())
        .await
    {
        Ok(ResendVerifyOutcome::Sent) => ResendOutcome::Sent,
        Ok(ResendVerifyOutcome::AlreadyActive) => ResendOutcome::AlreadyActive,
        Ok(ResendVerifyOutcome::UnknownEmail) => ResendOutcome::UnknownEmail,
        Err(_) => ResendOutcome::UnknownEmail,
    }
}

/// Delete the signed-in account. Unwires machines and sessions; never
/// wipes the customer's box.
pub async fn delete_account(backend: &SiteBackend, email: &str) -> Result<(), AccountError> {
    backend.cp.account_delete(email).await
}
