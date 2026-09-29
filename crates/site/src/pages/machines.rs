//! The owner's machines dashboard: generate an invite link, approve the
//! machine that claimed it with a name, and see it listed.
//!
//! The shared [`fortress_web_ui::MachinesPage`] emits absolute, fixed
//! form paths — `/auth/invite`,
//! `/auth/invite/{code}/{approve,deny,revoke}` — so this module must
//! serve exactly those. The paths are hardcoded in web-ui instead of
//! passed as props precisely so every surface that renders the
//! dashboard serves one contract.
//!
//! PRG everywhere: every mutating handler answers with a 303 back to
//! `/machines` carrying `?invited=<code>` or `?error=<ident>`. The
//! query never carries a message or a credential — see the `auth.rs`
//! law.

use topcoat::{
    Result as TcResult,
    context::Cx,
    router::{HeaderMap, StatusCode, content::Form, page, path_param, query_params},
    view::{Unescaped, View, view},
};

use crate::account::{
    self, InviteCreateOutcome, InviteDecisionOutcome, SessionState,
};
use crate::pages::auth::{location_header, signed_in_email};

path_param!(code);

/// `?invited=<code>` highlights the invite just generated (the share
/// link is shown only for that one); `?error=<ident>` is the PRG token
/// [`alert`] turns into a banner.
#[query_params(error = bad_request)]
#[derive(Default, Clone)]
struct MachinesQuery {
    invited: Option<String>,
    error: Option<String>,
}

/// The approve form's body. Public because `#[page]` generates a props
/// type that names it.
#[derive(Debug, serde::Deserialize)]
pub struct ApproveForm {
    pub name: String,
}

fn machines_query(cx: &Cx) -> MachinesQuery {
    let fallback = MachinesQuery::default();
    query_params::<MachinesQuery>(cx).unwrap_or(&fallback).clone()
}

/// The banner text for a PRG error token. Tokens only — never a message
/// in the URL — so the wording lives here and not in a redirect.
fn alert(code: &str) -> Option<&'static str> {
    Some(match code {
        "name_taken" => "That name is already taken — generate a new invite and pick another.",
        "invalid_name" => {
            "That name isn't valid — 6+ characters, lowercase letters, digits, hyphens."
        }
        "not_waiting" => "That invite is no longer waiting — generate a new one.",
        "not_begun" => "No machine has claimed that invite yet — share the link first.",
        "invalid_code" => "That invite code isn't valid.",
        "failed" => "Something went wrong. Try again.",
        _ => return None,
    })
}

/// The signed-in dashboard, or the login page.
///
/// One `view!` for both outcomes: `impl View` is a single opaque type,
/// so a 303 and a 200 page have to be the same shape with runtime
/// parts rather than two macro invocations.
#[page("/machines")]
pub async fn machines(cx: &Cx) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let (status, head, body) = match account::current_session(backend, &request_headers).await {
        SessionState::Anonymous => {
            let mut head = HeaderMap::new();
            let (name, value) = location_header("/login");
            head.insert(name, value);
            (StatusCode::SEE_OTHER, head, String::new())
        }
        SessionState::LoggedIn { email } => {
            let query = machines_query(cx);
            let error = query.error.as_deref().and_then(alert).map(str::to_string);
            let props = account::dashboard(backend, &email, query.invited, error).await;
            (StatusCode::OK, HeaderMap::new(), fortress_web_ui::machines_html(&props))
        }
    };
    Ok(view! {
        (status)
        (head)
        (Unescaped::new_unchecked(body))
    })
}

/// Generate an invite link and come back showing it.
#[page(POST "/auth/invite")]
pub async fn invite_create(cx: &Cx) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let location = match signed_in_email(backend, &request_headers).await {
        None => "/login".to_string(),
        Some(email) => match account::create_invite(backend, &email).await {
            InviteCreateOutcome::Created { code } => format!("/machines?invited={code}"),
            InviteCreateOutcome::Error { code } => format!("/machines?error={code}"),
        },
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

/// Approve the machine that claimed `code` and name it. The only step
/// that allocates a WireGuard peer and a DNS record.
#[page(POST "/auth/invite/{code}/approve")]
pub async fn invite_approve(cx: &Cx, Form(form): Form<ApproveForm>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let code = path_param::<Code>(cx);
    let location = match signed_in_email(backend, &request_headers).await {
        None => "/login".to_string(),
        Some(email) => {
            match account::approve_invite(backend, &email, code, form.name.trim()).await {
                InviteDecisionOutcome::Done => "/machines".to_string(),
                InviteDecisionOutcome::Error { code: err_code } => {
                    format!("/machines?error={err_code}")
                }
            }
        }
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

/// Deny a machine that claimed the invite (burns the code).
#[page(POST "/auth/invite/{code}/deny")]
pub async fn invite_deny(cx: &Cx) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let code = path_param::<Code>(cx);
    let location = match signed_in_email(backend, &request_headers).await {
        None => "/login".to_string(),
        Some(email) => match account::deny_invite(backend, &email, code).await {
            InviteDecisionOutcome::Done => "/machines".to_string(),
            InviteDecisionOutcome::Error { code: err_code } => {
                format!("/machines?error={err_code}")
            }
        },
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

/// Revoke a waiting invite before any machine has claimed it.
#[page(POST "/auth/invite/{code}/revoke")]
pub async fn invite_revoke(cx: &Cx) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let code = path_param::<Code>(cx);
    let location = match signed_in_email(backend, &request_headers).await {
        None => "/login".to_string(),
        Some(email) => match account::revoke_invite(backend, &email, code).await {
            InviteDecisionOutcome::Done => "/machines".to_string(),
            InviteDecisionOutcome::Error { code: err_code } => {
                format!("/machines?error={err_code}")
            }
        },
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}
