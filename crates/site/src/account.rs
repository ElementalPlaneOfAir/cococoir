//! The account lifecycle and enrollment bridge between the topcoat
//! pages and the embedded [`SiteBackend`].
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
use fortress_controlplane::controlplane::pairing::InviteError;
use fortress_controlplane::controlplane::web::{
    clear_session_cookie_header, machines_props, read_cookie_from_headers, session_cookie_header,
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
        .account_signup(email, password, backend.mailer)
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
        .request_password_reset(email, backend.mailer)
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
        .resend_verification(email, backend.mailer)
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

// ── the enrollment plane (invites + machines) ──────────────────────

/// Outcome of generating an invite link for a machine to claim.
#[derive(Debug, Clone, PartialEq)]
pub enum InviteCreateOutcome {
    Created { code: String },
    Error { code: &'static str },
}

/// Outcome of the owner's decision on an invite.
#[derive(Debug, Clone, PartialEq)]
pub enum InviteDecisionOutcome {
    Done,
    Error { code: &'static str },
}

/// The owner's dashboard view-model, already mapped onto the shared
/// component's rows by the poem surface's mapper — one mapping, both
/// surfaces. `invited_code` and `error` are request-derived, so the
/// page fills them in from the query.
pub async fn dashboard(
    backend: &SiteBackend,
    email: &str,
    invited_code: Option<String>,
    error: Option<String>,
) -> fortress_web_ui::MachinesProps {
    assert!(!email.is_empty(), "the dashboard needs a signed-in account");
    machines_props(
        backend.cp.machines_of(email).await.unwrap_or_default(),
        backend.cp.invites_of(email).await.unwrap_or_default(),
        invited_code,
        backend.cp.root_domain().to_string(),
        error,
    )
}

/// Generate a single-use invite link for a machine to claim.
pub async fn create_invite(backend: &SiteBackend, email: &str) -> InviteCreateOutcome {
    match backend.cp.invite_create(email).await {
        Ok(code) => InviteCreateOutcome::Created { code },
        Err(err) => InviteCreateOutcome::Error {
            code: invite_error_code(&err),
        },
    }
}

/// Approve the machine that claimed `code` and give it a name. This is
/// the step that allocates it a WireGuard peer and a DNS record, so it
/// needs the process forwarder — `init_globals` installs it at boot.
pub async fn approve_invite(
    backend: &SiteBackend,
    email: &str,
    code: &str,
    name: &str,
) -> InviteDecisionOutcome {
    match backend.cp.invite_approve(email, code, name).await {
        Ok(_) => InviteDecisionOutcome::Done,
        Err(err) => InviteDecisionOutcome::Error {
            code: invite_error_code(&err),
        },
    }
}

/// Deny a machine that claimed the invite (burns the code).
pub async fn deny_invite(
    backend: &SiteBackend,
    email: &str,
    code: &str,
) -> InviteDecisionOutcome {
    match backend.cp.invite_deny(email, code).await {
        Ok(()) => InviteDecisionOutcome::Done,
        Err(err) => InviteDecisionOutcome::Error {
            code: invite_error_code(&err),
        },
    }
}

/// Revoke a waiting invite before any machine has claimed it.
pub async fn revoke_invite(
    backend: &SiteBackend,
    email: &str,
    code: &str,
) -> InviteDecisionOutcome {
    match backend.cp.invite_revoke(email, code).await {
        Ok(()) => InviteDecisionOutcome::Done,
        Err(err) => InviteDecisionOutcome::Error {
            code: invite_error_code(&err),
        },
    }
}

/// Map an [`InviteError`] onto a short PRG token — never a message, per
/// the auth pages' law. The name errors stay distinct because they are
/// the one distinction that changes what the customer does next (pick a
/// different name, or generate a fresh invite).
pub fn invite_error_code(err: &InviteError) -> &'static str {
    match err {
        InviteError::NameTaken(_) => "name_taken",
        InviteError::InvalidName(_) => "invalid_name",
        InviteError::NotWaiting(_) => "not_waiting",
        InviteError::NotBegun(_) => "not_begun",
        InviteError::InvalidCode(_) => "invalid_code",
        InviteError::Unknown(_)
        | InviteError::Forbidden(_)
        | InviteError::InvalidPubkey(_)
        | InviteError::Corrupt(_)
        | InviteError::Account(_)
        | InviteError::Redis(_) => "failed",
    }
}

#[cfg(test)]
mod enrollment_mapping_tests {
    use super::invite_error_code;
    use fortress_controlplane::controlplane::pairing::InviteError;

    #[test]
    fn name_errors_stay_distinct_from_the_generic_failure() {
        assert_eq!(
            invite_error_code(&InviteError::NameTaken("living-room".into())),
            "name_taken"
        );
        assert_eq!(
            invite_error_code(&InviteError::InvalidName("UPPER".into())),
            "invalid_name"
        );
    }

    #[test]
    fn lifecycle_errors_map_to_actionable_tokens() {
        assert_eq!(
            invite_error_code(&InviteError::NotWaiting("C0DE000001".into())),
            "not_waiting"
        );
        assert_eq!(
            invite_error_code(&InviteError::NotBegun("C0DE000001".into())),
            "not_begun"
        );
        assert_eq!(
            invite_error_code(&InviteError::InvalidCode("bad".into())),
            "invalid_code"
        );
    }

    #[test]
    fn store_and_foreign_failures_never_leak_detail() {
        for err in [
            InviteError::Unknown("C0DE000001".into()),
            InviteError::Forbidden("C0DE000001".into()),
            InviteError::InvalidPubkey("pk".into()),
            InviteError::Corrupt("record".into()),
        ] {
            assert_eq!(
                invite_error_code(&err),
                "failed",
                "internal detail must not reach the query string: {err}"
            );
        }
    }
}
