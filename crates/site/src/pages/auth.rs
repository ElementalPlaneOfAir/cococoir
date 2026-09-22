//! The account surfaces: register, login, forgot, reset, verify, resend,
//! the `/a/{code}` join page, and account deletion.
//!
//! **Post/Redirect/Get, always.** Every mutating handler responds with a
//! 303 to a GET. Failures redirect with a short `error=<code>` token —
//! never a message, never a credential. A credential in a URL is a leak
//! into browser history, server logs and Referer headers; the dioxus
//! port shipped exactly that bug (a method-less `<form>` defaults to
//! GET) and `credential_forms_declare_post` exists so it cannot return.
//!
//! Each handler ends in exactly one `view!` (GETs wrap a trusted HTML
//! string, POSTs build a 303). `view!` only expands inside `#[page]` /
//! `#[component]` — it reaches for the macro-injected `__cx` — so the
//! builders here return `String`, never `impl View`.

use topcoat::{
    Result as TcResult,
    context::Cx,
    router::{
        HeaderMap, HeaderValue, StatusCode,
        content::Form,
        error::not_found,
        header, page, path_param, query_params,
    },
    view::{Unescaped, View, view},
};

use crate::SiteBackend;
use crate::account::{
    self, ForgotOutcome, LoginOutcome, ResendOutcome, ResetOutcome, SessionState, SignupOutcome,
    VerifyOutcome,
};

path_param!(code);

// ── tiny template builders (HTML text only — no View) ───────────────

pub(crate) fn field(label: &str, input: &str) -> String {
    format!("<label class=\"block\"><div class=\"tag dim mb-1\">{label}</div>{input}</label>")
}

pub(crate) fn text_input(name: &str, kind: &str) -> String {
    let autocomplete = if kind == "password" { "current-password" } else { "email" };
    format!(
        "<input class=\"zine-input\" type=\"{kind}\" name=\"{name}\" autocomplete=\"{autocomplete}\" required />"
    )
}

pub(crate) fn submit(label: &str) -> String {
    format!("<button type=\"submit\" class=\"btn-zine btn-zine-red\">{label}</button>")
}

/// `method="post"` is load-bearing: it is the no-JS floor that keeps
/// credentials out of the query string. `credential_forms_declare_post`
/// asserts it.
pub(crate) fn form(action: &str, fields: &[String]) -> String {
    format!(
        "<form class=\"flex flex-col gap-4\" method=\"post\" action=\"{action}\">{}</form>",
        fields.concat()
    )
}

pub(crate) fn auth_shell(title: &str, banner: Option<&str>, body: &str) -> String {
    let banner_html = match banner {
        Some(message) => {
            format!("<div role=\"alert\" class=\"alert-zine\">{message}</div>")
        }
        None => String::new(),
    };
    format!(
        "<main class=\"mx-auto flex max-w-md flex-col gap-4 p-6\">\
           <h1 class=\"text-2xl font-black uppercase\">{title}</h1>\
           {banner_html}\
           {body}\
         </main>"
    )
}

fn alert(code: &str) -> Option<&'static str> {
    Some(match code {
        "exists" => "That email already has an account — log in, or reset your password.",
        "unknown" => "No account with that email — sign up first.",
        "bad_credentials" => "That email and password do not match.",
        "needs_verify" => "Verify your email first — check your inbox for the confirmation link.",
        "invalid_token" => "That link is invalid or has already been used.",
        "mail_failed" => "We could not send the email. Try again in a moment.",
        "failed" => "Something went wrong. Try again.",
        _ => return None,
    })
}

fn location_header(value: &str) -> (header::HeaderName, HeaderValue) {
    (
        header::LOCATION,
        HeaderValue::from_str(value).expect("redirect location is a valid header value"),
    )
}

// ── query shapes (`error = <ident>` is the parse-failure response) ───

#[query_params(error = bad_request)]
#[derive(Default, Clone)]
struct AuthQuery {
    error: Option<String>,
    check: Option<String>,
    verified: Option<String>,
    reset: Option<String>,
    sent: Option<String>,
}

#[query_params(error = bad_request)]
#[derive(Default, Clone)]
struct TokenQuery {
    token: Option<String>,
    error: Option<String>,
}

#[query_params(error = bad_request)]
#[derive(Default, Clone)]
struct ResetQuery {
    token: Option<String>,
    error: Option<String>,
}

#[query_params(error = bad_request)]
#[derive(Default, Clone)]
struct ResendQuery {
    email: Option<String>,
    error: Option<String>,
    sent: Option<String>,
}

#[query_params(error = bad_request)]
#[derive(Default, Clone)]
struct AccountQuery {
    error: Option<String>,
    deleted: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
pub struct Credentials {
    pub email: String,
    pub password: String,
}

#[derive(Debug, serde::Deserialize)]
pub struct EmailForm {
    pub email: String,
}

#[derive(Debug, serde::Deserialize)]
pub struct TokenForm {
    pub token: String,
}

#[derive(Debug, serde::Deserialize)]
pub struct ResetForm {
    pub token: String,
    pub password: String,
}

fn auth_query(cx: &Cx) -> AuthQuery {
    let fallback = AuthQuery::default();
    query_params::<AuthQuery>(cx).unwrap_or(&fallback).clone()
}

fn token_query(cx: &Cx) -> TokenQuery {
    let fallback = TokenQuery::default();
    query_params::<TokenQuery>(cx).unwrap_or(&fallback).clone()
}

fn reset_query(cx: &Cx) -> ResetQuery {
    let fallback = ResetQuery::default();
    query_params::<ResetQuery>(cx).unwrap_or(&fallback).clone()
}

fn resend_query(cx: &Cx) -> ResendQuery {
    let fallback = ResendQuery::default();
    query_params::<ResendQuery>(cx).unwrap_or(&fallback).clone()
}

fn account_query(cx: &Cx) -> AccountQuery {
    let fallback = AccountQuery::default();
    query_params::<AccountQuery>(cx).unwrap_or(&fallback).clone()
}

// ── register ───────────────────────────────────────────────────────

#[page("/register")]
pub async fn register_get(cx: &Cx) -> TcResult<impl View> {
    let q = auth_query(cx);
    let mut banner = q.error.as_deref().and_then(alert);
    if q.check.is_some() {
        banner = Some("Check your email — we sent a confirmation link.");
    }
    let body = form(
        "/register",
        &[
            field("Email", &text_input("email", "email")),
            field("Password", &text_input("password", "password")),
            submit("Sign up"),
        ],
    ) + "<p class=\"text-sm dim\">Already have an account? <a class=\"link-zine\" href=\"/login\">Log in</a></p>";
    let html = auth_shell("Create an account", banner, &body);
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/register")]
pub async fn register_post(cx: &Cx, Form(creds): Form<Credentials>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let location = match account::signup(backend, &creds.email, &creds.password).await {
        SignupOutcome::Created => "/register?check=1".to_string(),
        SignupOutcome::Error { code } => format!("/register?error={code}"),
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

// ── login / logout ─────────────────────────────────────────────────

#[page("/login")]
pub async fn login_get(cx: &Cx) -> TcResult<impl View> {
    let q = auth_query(cx);
    let mut banner = q.error.as_deref().and_then(alert);
    if q.verified.is_some() {
        banner = Some("Email verified — you can log in now.");
    }
    if q.reset.is_some() {
        banner = Some("Password reset — log in with the new one.");
    }
    let body = form(
        "/login",
        &[
            field("Email", &text_input("email", "email")),
            field("Password", &text_input("password", "password")),
            submit("Log in"),
        ],
    ) + "<p class=\"text-sm dim\"><a class=\"link-zine\" href=\"/forgot\">Forgot your password?</a></p>";
    let html = auth_shell("Log in", banner, &body);
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/login")]
pub async fn login_post(cx: &Cx, Form(creds): Form<Credentials>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let (location, cookie) = match account::login(backend, &creds.email, &creds.password).await {
        LoginOutcome::Ok { cookie } => ("/".to_string(), Some(cookie)),
        LoginOutcome::NeedsVerification => (
            format!("/resend?error=needs_verify&email={}", creds.email),
            None,
        ),
        LoginOutcome::Error { code } => (format!("/login?error={code}"), None),
    };
    let mut headers = HeaderMap::new();
    headers.insert(location_header(&location).0, location_header(&location).1);
    if let Some(cookie) = cookie {
        headers.insert(header::SET_COOKIE, cookie);
    }
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (headers)
        ""
    })
}

#[page(POST "/logout")]
pub async fn logout_post(cx: &Cx) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let clear = account::logout(backend, &request_headers).await;
    let mut headers = HeaderMap::new();
    let (name, value) = location_header("/");
    headers.insert(name, value);
    headers.insert(header::SET_COOKIE, clear);
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (headers)
        ""
    })
}

// ── forgot / reset ─────────────────────────────────────────────────

#[page("/forgot")]
pub async fn forgot_get(cx: &Cx) -> TcResult<impl View> {
    let q = auth_query(cx);
    let mut banner = q.error.as_deref().and_then(alert);
    if q.sent.is_some() {
        banner = Some("If that address has an account, a reset link is on its way.");
    }
    let body = form(
        "/forgot",
        &[
            field("Email", &text_input("email", "email")),
            submit("Send reset link"),
        ],
    ) + "<p class=\"text-sm dim\"><a class=\"link-zine\" href=\"/login\">Back to log in</a></p>";
    let html = auth_shell("Reset your password", banner, &body);
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/forgot")]
pub async fn forgot_post(cx: &Cx, Form(form): Form<EmailForm>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let location = match account::forgot(backend, &form.email).await {
        // Both outcomes land on the same "check your inbox" page. The
        // UnknownEmail distinction lives on the GET page (it links to
        // /register) — honest, but not an oracle in the redirect.
        ForgotOutcome::Sent | ForgotOutcome::UnknownEmail => "/forgot?sent=1".to_string(),
        ForgotOutcome::Error { code } => format!("/forgot?error={code}"),
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

#[page("/reset")]
pub async fn reset_get(cx: &Cx) -> TcResult<impl View> {
    let q = reset_query(cx);
    let Some(token) = q.token.as_deref().filter(|t| !t.is_empty()) else {
        return Err(not_found().into());
    };
    let body = form(
        "/reset",
        &[
            format!("<input type=\"hidden\" name=\"token\" value=\"{token}\" />"),
            field("New password", &text_input("password", "password")),
            submit("Set new password"),
        ],
    );
    let html = auth_shell("Choose a new password", q.error.as_deref().and_then(alert), &body);
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/reset")]
pub async fn reset_post(cx: &Cx, Form(form): Form<ResetForm>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let location = match account::reset(backend, &form.token, &form.password).await {
        ResetOutcome::Done => "/login?reset=1".to_string(),
        ResetOutcome::Invalid => "/reset?error=invalid_token".to_string(),
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

// ── verify / resend ────────────────────────────────────────────────

/// The verify *page*. Deliberately does NOT consume the token: mail
/// scanners prefetch links, and a GET that mutates would burn the token
/// before the customer ever clicks (the poem surface learned this the
/// same way). POST consumes.
#[page("/verify")]
pub async fn verify_get(cx: &Cx) -> TcResult<impl View> {
    let q = token_query(cx);
    let Some(token) = q.token.as_deref().filter(|t| !t.is_empty()) else {
        return Err(not_found().into());
    };
    let body = form(
        "/verify",
        &[
            format!("<input type=\"hidden\" name=\"token\" value=\"{token}\" />"),
            submit("Verify my email"),
        ],
    );
    let html = auth_shell("Confirm your email", q.error.as_deref().and_then(alert), &body);
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/verify")]
pub async fn verify_post(cx: &Cx, Form(form): Form<TokenForm>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let location = match account::verify(backend, &form.token).await {
        VerifyOutcome::Activated => "/login?verified=1".to_string(),
        VerifyOutcome::Invalid => "/verify?error=invalid_token".to_string(),
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

#[page("/resend")]
pub async fn resend_get(cx: &Cx) -> TcResult<impl View> {
    let q = resend_query(cx);
    let mut banner = q.error.as_deref().and_then(alert);
    if q.sent.is_some() {
        banner = Some("Check your inbox for the confirmation link.");
    }
    let prefill = q.email.as_deref().unwrap_or_default();
    let input = format!(
        "<input class=\"zine-input\" type=\"email\" name=\"email\" value=\"{prefill}\" required />"
    );
    let body = form(
        "/resend",
        &[field("Email", &input), submit("Resend verification")],
    );
    let html = auth_shell("Verify your email", banner, &body);
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/resend")]
pub async fn resend_post(cx: &Cx, Form(form): Form<EmailForm>) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let location = match account::resend(backend, &form.email).await {
        ResendOutcome::Sent | ResendOutcome::AlreadyActive => "/resend?sent=1".to_string(),
        ResendOutcome::UnknownEmail => {
            format!("/resend?error=unknown&email={}", form.email)
        }
    };
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (location_header(&location))
        ""
    })
}

// ── the invite join page ───────────────────────────────────────────

/// `GET /a/{code}` — the human half of an invite. The machine dials
/// `/api/invites/{code}/begin` (axum, the machine contract); this page
/// explains what to do with the invite URL.
#[page("/a/{code}")]
pub async fn join(cx: &Cx) -> TcResult<impl View> {
    let code = path_param::<Code>(cx);
    let html = format!(
        "<main class=\"mx-auto flex max-w-md flex-col gap-4 p-6\">\
           <h1 class=\"text-2xl font-black uppercase\">Join Fortress</h1>\
           <p>Open this invite URL on the machine you want to enroll. \
              It will ask the edge to register itself and then download its \
              tunnel configuration.</p>\
           <p class=\"text-sm dim\">Invite code <code>{code}</code> is single-use \
              and expires in 30 days.</p>\
           <p class=\"text-sm dim\">Not a machine? \
              <a class=\"link-zine\" href=\"/register\">Create an account</a>.</p>\
         </main>"
    );
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

// ── account deletion ───────────────────────────────────────────────

#[page("/account/delete")]
pub async fn account_delete_get(cx: &Cx) -> TcResult<impl View> {
    let q = account_query(cx);
    let html = if q.deleted.is_some() {
        fortress_web_ui::landing_html(&fortress_web_ui::LandingProps {
            logged_in: false,
            email: None,
        })
    } else {
        let mut banner = q.error.as_deref().and_then(alert);
        if banner.is_none() {
            banner = Some("This cannot be undone.");
        }
        let body = form("/account/delete", &[submit("Delete my account permanently")])
            + "<p class=\"text-sm dim\">This unwires every machine you enrolled. \
                 It does <strong>not</strong> wipe your box.</p>";
        auth_shell("Delete your account", banner, &body)
    };
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page(POST "/account/delete")]
pub async fn account_delete_post(cx: &Cx) -> TcResult<impl View> {
    let backend = crate::site_backend(cx);
    let request_headers: HeaderMap = topcoat::router::request::headers(cx).clone();
    let mut headers = HeaderMap::new();
    match signed_in_email(backend, &request_headers).await {
        None => {
            let (name, value) = location_header("/login");
            headers.insert(name, value);
        }
        Some(email) => match account::delete_account(backend, &email).await {
            Ok(()) => {
                let clear = account::logout(backend, &request_headers).await;
                let (name, value) = location_header("/account/delete?deleted=1");
                headers.insert(name, value);
                headers.insert(header::SET_COOKIE, clear);
            }
            Err(_) => {
                let (name, value) = location_header("/account/delete?error=failed");
                headers.insert(name, value);
            }
        },
    }
    Ok(view! {
        (StatusCode::SEE_OTHER)
        (headers)
        ""
    })
}

async fn signed_in_email(backend: &SiteBackend, headers: &HeaderMap) -> Option<String> {
    match account::current_session(backend, headers).await {
        SessionState::LoggedIn { email } => Some(email),
        SessionState::Anonymous => None,
    }
}
