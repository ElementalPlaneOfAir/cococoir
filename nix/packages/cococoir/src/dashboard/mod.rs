pub mod auth;
pub mod components;
mod db;
mod nix_config_parser;

use crate::dashboard::auth::{
    clear_session_cookie_header, gate_request, read_cookie, session_cookie_header, verify_password,
    AuthMode, SESSION_COOKIE,
};
use crate::dashboard::db::{Db, DbError};
use crate::dashboard::components::{
    HtmxTest, HtmxTestProps, IndexPage, IndexProps, LoginPage, LoginPageProps,
};
use momenta::prelude::*;
use poem::{
    get, handler,
    http::{header, StatusCode},
    listener::TcpListener,
    post,
    web::{Data, Form, Html, Path, Redirect},
    Endpoint, EndpointExt, IntoResponse, Request, Response, Route, Server,
};
use serde::Deserialize;
use std::time::Duration;
use tokio::time::sleep;

const PAGE_LOAD_KEY: &str = "page_loads";

async fn next_page_load(db: &Db) -> usize {
    let current = db
        .kv_get(PAGE_LOAD_KEY)
        .await
        .ok()
        .flatten()
        .and_then(|raw| raw.parse::<usize>().ok())
        .unwrap_or(1);
    let next = current + 1;
    if let Err(error) = db.kv_set(PAGE_LOAD_KEY, &next.to_string()).await {
        tracing::warn!(error = %error, "failed to persist page load counter; page still renders");
    }
    current
}

#[handler]
async fn index(Data(db): Data<&Db>) -> impl IntoResponse {
    let times_loaded = next_page_load(db).await;
    let props = IndexProps {
        name: "dashboard".to_string(),
        count: times_loaded,
    };
    Html(component::<IndexPage>(props).to_html()).with_status(StatusCode::OK)
}

#[handler]
async fn hello(Data(db): Data<&Db>, Path(name): Path<String>) -> impl IntoResponse {
    let times_loaded = next_page_load(db).await;
    let props = IndexProps {
        name,
        count: times_loaded,
    };
    Html(component::<IndexPage>(props).to_html()).with_status(StatusCode::OK)
}

#[handler]
async fn update_count(Data(db): Data<&Db>) -> Response {
    let times_loaded = next_page_load(db).await;
    sleep(Duration::from_millis(500)).await;
    let props = HtmxTestProps {
        count: times_loaded,
    };
    Html(component::<HtmxTest>(props).to_html())
        .with_status(StatusCode::OK)
        .into_response()
}

#[handler]
async fn create_session(Data(db): Data<&Db>) -> Response {
    match db.create_session("demo-user").await {
        Ok(token) => Html(format!("<p>session created: {token}</p>"))
            .with_header("X-Session-Token", token)
            .with_status(StatusCode::CREATED)
            .into_response(),
        Err(error) => {
            tracing::error!(error = %error, "create session failed");
            Html("<p>session creation failed</p>".to_string())
                .with_status(StatusCode::INTERNAL_SERVER_ERROR)
                .into_response()
        }
    }
}

#[handler]
async fn show_session(Data(db): Data<&Db>, Path(token): Path<String>) -> Response {
    match db.get_session(&token).await {
        Ok(session) => Html(format!(
            "<p>session for {user} created {created} valid until {expires}</p>",
            user = session.user_id,
            created = session.created_at.to_rfc3339(),
            expires = session.expires_at.to_rfc3339(),
        ))
        .into_response(),
        Err(DbError::SessionNotFound(_)) => StatusCode::NOT_FOUND.into(),
        Err(DbError::SessionExpired(_)) => StatusCode::GONE.into(),
        Err(error) => {
            tracing::error!(error = %error, token = %token, "get session failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn end_session(Data(db): Data<&Db>, Path(token): Path<String>) -> Response {
    match db.delete_session(&token).await {
        Ok(true) => StatusCode::NO_CONTENT.into(),
        Ok(false) => StatusCode::NOT_FOUND.into(),
        Err(error) => {
            tracing::error!(error = %error, token = %token, "delete session failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Debug, Deserialize)]
struct LoginForm {
    password: Option<String>,
}

/// The admin login page. Rendered on GET; a wrong password re-renders
/// it with the error flag set so the browser keeps the page.
fn login_page(error: bool) -> Response {
    let props = LoginPageProps { error };
    Html(component::<LoginPage>(props).to_html())
        .with_status(StatusCode::OK)
        .into_response()
}

#[handler]
async fn login_page_get(Data(auth): Data<&AuthMode>) -> Response {
    if auth.config().is_none() {
        return Redirect::see_other("/").into_response();
    }
    login_page(false)
}

#[handler]
async fn login_page_post(
    Data(db): Data<&Db>,
    Data(auth): Data<&AuthMode>,
    Form(form): Form<LoginForm>,
) -> Response {
    let Some(config) = auth.config() else {
        return Redirect::see_other("/").into_response();
    };
    // A missing password field fails the same way as a wrong one.
    let Some(password) = form.password.as_deref() else {
        return login_page(true);
    };
    if !verify_password(password, &config.password_hash) {
        return login_page(true);
    }
    match db.create_session("admin").await {
        Ok(token) => Response::builder()
            .status(StatusCode::SEE_OTHER)
            .header(header::LOCATION, "/")
            .header(header::SET_COOKIE, session_cookie_header(&token, false))
            .finish(),
        Err(error) => {
            tracing::error!(error = %error, "session creation failed after login");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn logout(Data(db): Data<&Db>, req: &Request) -> Response {
    if let Some(token) = read_cookie(req, SESSION_COOKIE) {
        let _ = db.delete_session(&token).await;
    }
    Response::builder()
        .status(StatusCode::SEE_OTHER)
        .header(header::LOCATION, "/")
        .header(header::SET_COOKIE, clear_session_cookie_header())
        .finish()
}

fn app(db: Db, auth: AuthMode) -> impl Endpoint {
    let gate_auth = auth.clone();
    let protected = Route::new()
        .at("/", get(index))
        .at("/hello/:name", get(hello))
        .at("/update", post(update_count))
        .at("/session", post(create_session))
        .at("/session/:token", get(show_session).delete(end_session))
        .around(move |ep, req| {
            let auth = gate_auth.clone();
            async move { gate_request(&auth, ep, req).await }
        });

    Route::new()
        .at("/auth/login", get(login_page_get).post(login_page_post))
        .at("/auth/logout", get(logout))
        .nest("/", protected)
        .data(db)
        .data(auth)
}

pub async fn dashboard_entry() -> Result<(), std::io::Error> {
    let db = Db::open().await.map_err(|error| {
        tracing::error!(error = %error, "dashboard database failed to open");
        std::io::Error::other("dashboard database failed to open")
    })?;
    Server::new(TcpListener::bind("0.0.0.0:3000"))
        .run(app(db, AuthMode::current().clone()))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use poem::test::TestClient;

    fn test_auth() -> AuthMode {
        AuthMode::Password(auth::AdminConfig {
            password_hash: "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W".to_string(),
        })
    }

    #[tokio::test]
    async fn hello_renders_and_counter_persists() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev));
        let first = client.get("/hello/alice").send().await;
        first.assert_status(StatusCode::OK);
        let first_body = first.0.into_body().into_string().await.expect("utf8 body");
        assert!(first_body.contains("alice"));
        assert!(first_body.contains(" 1 times."));
        let second = client.get("/hello/alice").send().await;
        let second_body = second.0.into_body().into_string().await.expect("utf8 body");
        assert!(second_body.contains(" 2 times."));
    }

    #[tokio::test]
    async fn session_endpoints_round_trip() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev));
        let created = client.post("/session").send().await;
        created.assert_status(StatusCode::CREATED);
        let token = created
            .0
            .headers()
            .get("X-Session-Token")
            .expect("token header present")
            .to_str()
            .expect("token header is utf8")
            .to_owned();
        let shown = client.get(format!("/session/{token}")).send().await;
        shown.assert_status(StatusCode::OK);
        let shown_body = shown.0.into_body().into_string().await.expect("utf8 body");
        assert!(shown_body.contains("demo-user"));
        let ended = client.delete(format!("/session/{token}")).send().await;
        ended.assert_status(StatusCode::NO_CONTENT);
        let gone = client.get(format!("/session/{token}")).send().await;
        gone.assert_status(StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn dev_mode_index_and_session_work_without_login() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev));
        let home = client.get("/").send().await;
        home.assert_status(StatusCode::OK);
        let login_redirect = client.get("/auth/login").send().await;
        login_redirect.assert_status(StatusCode::SEE_OTHER);
        let location = login_redirect
            .0
            .headers()
            .get(header::LOCATION)
            .expect("redirect location")
            .to_str()
            .unwrap()
            .to_owned();
        assert_eq!(location, "/");
    }

    #[tokio::test]
    async fn gate_bounces_unauthenticated_page_loads() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth()));
        let bounced = client.get("/").send().await;
        bounced.assert_status(StatusCode::SEE_OTHER);
        let location = bounced
            .0
            .headers()
            .get(header::LOCATION)
            .expect("redirect location")
            .to_str()
            .unwrap();
        assert_eq!(location, "/auth/login");
    }

    #[tokio::test]
    async fn gate_redirects_htmx_with_hx_header() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth()));
        let bounced = client
            .get("/hello/test")
            .header("HX-Request", "true")
            .send()
            .await;
        bounced.assert_status(StatusCode::UNAUTHORIZED);
        let hx = bounced
            .0
            .headers()
            .get("HX-Redirect")
            .expect("hx-redirect")
            .to_str()
            .unwrap();
        assert_eq!(hx, "/auth/login");
    }

    #[tokio::test]
    async fn gate_passes_valid_session_cookie() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let token = db.create_session("alice").await.expect("create session");
        let client = TestClient::new(app(db, test_auth()));
        let response = client
            .get("/hello/alice")
            .header(header::COOKIE, format!("cococoir_session={token}"))
            .send()
            .await;
        response.assert_status(StatusCode::OK);
    }

    #[tokio::test]
    async fn login_page_renders_in_password_mode() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth()));
        let response = client.get("/auth/login").send().await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Admin sign in"));
    }

    #[tokio::test]
    async fn login_grants_session_with_correct_password() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth()));
        let response = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body("password=password")
            .send()
            .await;
        response.assert_status(StatusCode::SEE_OTHER);
        let location = response
            .0
            .headers()
            .get(header::LOCATION)
            .expect("redirect location")
            .to_str()
            .unwrap();
        assert_eq!(location, "/");
        let set_cookie = response
            .0
            .headers()
            .get(header::SET_COOKIE)
            .expect("session cookie set")
            .to_str()
            .unwrap();
        assert!(set_cookie.contains("cococoir_session="));
        let token = set_cookie
            .split("cococoir_session=")
            .nth(1)
            .and_then(|rest| rest.split(';').next())
            .expect("cookie token");
        let gate = client
            .get("/hello/alice")
            .header(header::COOKIE, format!("cococoir_session={token}"))
            .send()
            .await;
        gate.assert_status(StatusCode::OK);
    }

    #[tokio::test]
    async fn login_rejects_wrong_password() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth()));
        let response = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body("password=hunter2")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Incorrect password."));
        let bounced = client.get("/").send().await;
        bounced.assert_status(StatusCode::SEE_OTHER);
    }

    #[tokio::test]
    async fn login_redirects_in_dev_mode() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev));
        let response = client.get("/auth/login").send().await;
        response.assert_status(StatusCode::SEE_OTHER);
        let location = response
            .0
            .headers()
            .get(header::LOCATION)
            .expect("redirect location")
            .to_str()
            .unwrap();
        assert_eq!(location, "/");
    }

    #[tokio::test]
    async fn logout_deletes_session_and_clears_cookie() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let token = db.create_session("bob").await.expect("create session");
        let client = TestClient::new(app(db.clone(), test_auth()));
        let response = client
            .get("/auth/logout")
            .header(header::COOKIE, format!("cococoir_session={token}"))
            .send()
            .await;
        response.assert_status(StatusCode::SEE_OTHER);
        let set_cookie = response
            .0
            .headers()
            .get(header::SET_COOKIE)
            .expect("cleared cookie")
            .to_str()
            .unwrap();
        assert!(set_cookie.contains("Max-Age=0"));
        assert!(matches!(
            db.get_session(&token).await,
            Err(DbError::SessionNotFound(_))
        ));
    }
}
