use poem::http::{header, HeaderValue, StatusCode};
use poem::{web::Redirect, Endpoint, IntoResponse, Request, Response};
use std::sync::{Arc, LazyLock};

use crate::dashboard::db::Db;

/// Browser session cookie. The value is the opaque token from the
/// `sessions` table; the browser re-sends it automatically on every
/// same-origin request, so htmx never handles auth itself.
pub const SESSION_COOKIE: &str = "cococoir_session";

/// Admin login configuration. The only credential is a bcrypt hash of
/// the admin password (set by `COCOCOIR_ADMIN_PASSWORD_HASH`; production
/// sources it from the box's secret store). The dashboard is the control
/// plane of the box, so it must NOT be reachable through the user-facing
/// OIDC provider — a compromise of Dex (or another provider) must never
/// grant full control of the system.
#[derive(Debug, Clone)]
pub struct AdminConfig {
    pub password_hash: String,
}

impl AdminConfig {
    fn from_env() -> Option<Self> {
        Some(Self {
            password_hash: std::env::var("COCOCOIR_ADMIN_PASSWORD_HASH").ok()?,
        })
    }
}

/// Auth posture. `Dev` = no login (local iteration); `Password` requires
/// a valid session cookie established by `POST /auth/login`.
#[derive(Debug, Clone)]
pub enum AuthMode {
    Dev,
    Password(AdminConfig),
}

impl AuthMode {
    fn from_env() -> Self {
        match AdminConfig::from_env() {
            Some(config) => Self::Password(config),
            None => Self::Dev,
        }
    }

    /// Admin config, or `None` in dev mode.
    pub fn config(&self) -> Option<&AdminConfig> {
        match self {
            Self::Dev => None,
            Self::Password(config) => Some(config),
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

/// Verify a submitted password against a bcrypt hash (cost >= 10).
/// Verification is constant-time inside the bcrypt crate. Any error —
/// malformed hash, invalid cost, unsupported format — reads as `false`:
/// a broken credential config must fail closed, never open.
pub fn verify_password(password: &str, hash: &str) -> bool {
    bcrypt::verify(password, hash).unwrap_or(false)
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

/// Login gate body. [`AuthMode::Dev`] passes every request through;
/// otherwise the session cookie must name a valid, unexpired session
/// row — else the request is bounced to the login page. The `Arc<E>`
/// param is poem's own `around` API, not our Arc usage.
pub async fn gate_request<E: Endpoint<Output = Response>>(
    auth: &AuthMode,
    endpoint: Arc<E>,
    req: Request,
) -> poem::Result<Response> {
    let AuthMode::Password(_config) = auth else {
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

#[cfg(test)]
mod tests {
    use super::*;

    const DEV_HASH: &str = "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W";

    #[test]
    fn verify_password_accepts_correct_password() {
        assert!(verify_password("password", DEV_HASH));
    }

    #[test]
    fn verify_password_rejects_wrong_password() {
        assert!(!verify_password("hunter2", DEV_HASH));
    }

    #[test]
    fn verify_password_fails_closed_on_garbage_hash() {
        assert!(!verify_password("password", "not-a-bcrypt-hash"));
        assert!(!verify_password("password", ""));
    }
}
