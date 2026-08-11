use poem::http::{header, HeaderValue, StatusCode};
use poem::{web::Redirect, Endpoint, IntoResponse, Request, Response};
use std::sync::{Arc, LazyLock};

use crate::dashboard::db::Db;

/// Browser session cookie. The value is the opaque token from the
/// `sessions` table; the browser re-sends it automatically on every
/// same-origin request, so htmx never handles auth itself.
pub const SESSION_COOKIE: &str = "cococoir_session";
/// Short-lived cookie pinning the OAuth `state` value to this browser.
pub const STATE_COOKIE: &str = "cococoir_oauth_state";
const STATE_COOKIE_TTL: u32 = 10 * 60;

/// OIDC provider configuration. The `COCOCOIR_OIDC_*` contract is set
/// by `apps.dashboard-dev` and, in production, by the dashboard's
/// nixos module.
#[derive(Debug, Clone)]
pub struct AuthConfig {
    pub issuer: String,
    pub client_id: String,
    pub client_secret: String,
    pub redirect_uri: String,
}

impl AuthConfig {
    fn from_env() -> Option<Self> {
        Some(Self {
            issuer: std::env::var("COCOCOIR_OIDC_ISSUER").ok()?,
            client_id: std::env::var("COCOCOIR_OIDC_CLIENT_ID").ok()?,
            client_secret: std::env::var("COCOCOIR_OIDC_CLIENT_SECRET").ok()?,
            redirect_uri: std::env::var("COCOCOIR_OIDC_REDIRECT_URI")
                .unwrap_or_else(|_| "http://localhost:3000/auth/callback".to_string()),
        })
    }

    /// Dex authorize URL for a fresh login attempt.
    pub fn authorize_url(&self, state: &str) -> String {
        format!(
            "{}/auth?client_id={}&redirect_uri={}&response_type=code&scope=openid+email&state={}",
            self.issuer, self.client_id, self.redirect_uri, state
        )
    }

    /// `Secure` only for https redirect URIs, so local http dev keeps working.
    pub fn secure(&self) -> bool {
        self.redirect_uri.starts_with("https://")
    }
}

/// Auth posture. `Dev` = no OIDC configured: the login gate is off and
/// the raw `/session` API stays usable as the test seam. `Oidc` carries
/// the provider config and turns the gate on.
#[derive(Debug, Clone)]
pub enum AuthMode {
    Dev,
    Oidc(AuthConfig),
}

impl AuthMode {
    fn from_env() -> Self {
        match AuthConfig::from_env() {
            Some(config) => Self::Oidc(config),
            None => Self::Dev,
        }
    }

    /// Provider config, or `None` in dev mode.
    pub fn config(&self) -> Option<&AuthConfig> {
        match self {
            Self::Dev => None,
            Self::Oidc(config) => Some(config),
        }
    }

    /// The process-wide auth mode, read from the environment once on
    /// first access and frozen. Production consumes this at the entry
    /// point; tests bypass it entirely by injecting an `AuthMode` into
    /// `app` (see mod.rs), so they stay hermetic and parallel-safe.
    pub fn current() -> &'static AuthMode {
        static AUTH_MODE: LazyLock<AuthMode> = LazyLock::new(AuthMode::from_env);
        &AUTH_MODE
    }
}

/// Read a cookie value by name from the request. `None` when absent.
pub fn read_cookie(req: &Request, name: &str) -> Option<String> {
    req.headers()
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .map(str::trim)
        .find_map(|part| {
            let (key, value) = part.split_once('=')?;
            (key == name).then(|| value.to_string())
        })
}

pub fn session_cookie_header(token: &str, secure: bool) -> HeaderValue {
    let mut cookie = format!("{SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Lax");
    if secure {
        cookie.push_str("; Secure");
    }
    HeaderValue::from_str(&cookie).expect("session cookie header is valid")
}

pub fn clear_session_cookie_header() -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
    ))
    .expect("cleared session cookie header is valid")
}

pub fn state_cookie_header(state: &str, secure: bool) -> HeaderValue {
    let mut cookie = format!(
        "{STATE_COOKIE}={state}; Path=/auth/callback; HttpOnly; SameSite=Lax; Max-Age={STATE_COOKIE_TTL}"
    );
    if secure {
        cookie.push_str("; Secure");
    }
    HeaderValue::from_str(&cookie).expect("state cookie header is valid")
}

/// Login gate body. [`AuthMode::Dev`] passes every request through;
/// otherwise the session cookie must name a valid, unexpired session
/// row — else the request is bounced to the login page. The `Arc<E>`
/// param is poem's own `around` API, not our Arc usage.
pub async fn gate_request<E: Endpoint<Output = Response>>(
    auth: &AuthMode,
    endpoint: Arc<E>,
    req: Request,
) -> poem::Result<Response> {
    let AuthMode::Oidc(_config) = auth else {
        return endpoint.call(req).await;
    };
    let authenticated = match (req.data::<Db>(), read_cookie(&req, SESSION_COOKIE)) {
        (Some(db), Some(token)) => matches!(db.get_session(&token).await, Ok(_)),
        _ => false,
    };
    if authenticated {
        return endpoint.call(req).await;
    }
    Ok(login_response(&req))
}

fn login_response(req: &Request) -> Response {
    if req.headers().contains_key("HX-Request") {
        // htmx drives requests with XHR; it won't navigate on a 3xx.
        // HX-Redirect makes it send the browser to the login page.
        Response::builder()
            .status(StatusCode::UNAUTHORIZED)
            .header("HX-Redirect", "/auth/login")
            .finish()
    } else {
        Redirect::see_other("/auth/login").into_response()
    }
}

/// Exchange the authorization code for tokens and return the verified
/// subject. NOT IMPLEMENTED — the real flow is:
///   1. POST {issuer}/token with grant_type=authorization_code, code,
///      redirect_uri, client_id, client_secret.
///   2. Verify the ID token signature against {issuer}/keys (RS256)
///      plus exp / iss / aud — without this, anyone can mint a login.
///   3. Return the `sub` claim to feed `Db::create_session`.
/// Candidate implementations: openidconnect (discovery + exchange +
/// verify in one) or reqwest + jsonwebtoken.
pub async fn exchange_code_and_verify(config: &AuthConfig, code: &str) -> Result<String, String> {
    let _ = (config, code);
    Err("token exchange not implemented; login cannot complete yet".to_string())
}
