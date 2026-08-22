pub mod auth;
pub mod components;
mod db;
pub mod nix_config_parser;

use crate::dashboard::auth::{
    clear_session_cookie_header, gate_request, read_cookie, session_cookie_header, verify_password,
    AuthMode, SESSION_COOKIE,
};
use crate::dashboard::db::{Db, DbError};
use crate::dashboard::components::{
    EditorPage, EditorPageProps, EditorServiceProps, EditorUserProps, HtmxTest, HtmxTestProps,
    IndexPage, IndexProps, LoginPage, LoginPageProps,
};
use crate::dashboard::nix_config_parser::{
    ConfigSchema, CococoirConfig, NixConfigFile, NixParseError, NixValue, SetError,
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
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::sleep;

const PAGE_LOAD_KEY: &str = "page_loads";

/// The dashboard-edited Nix config file. Resolved once from the
/// `COCOCOIR_CONFIG_PATH` env var; falls back to the repo-relative
/// `nixosConfigurations/dashboard.nix` for the dev loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigPath(PathBuf);

impl ConfigPath {
    fn resolve() -> Self {
        Self(
            std::env::var_os("COCOCOIR_CONFIG_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("nixosConfigurations/dashboard.nix")),
        )
    }

    pub fn as_path(&self) -> &std::path::Path {
        &self.0
    }
}

/// Failures reading the config file. Surfaced in the editor UI; never a
/// panic. `NotFound` and `Parse` are distinct so the UI can say
/// "create the file first" vs "your file is not valid Nix".
#[derive(Debug, thiserror::Error)]
pub enum ConfigReadError {
    #[error("config file not found at {0}")]
    NotFound(PathBuf),
    #[error("config file unreadable at {0}: {1}")]
    Io(PathBuf, std::io::Error),
    #[error("config file is not valid Nix: {0}")]
    Parse(NixParseError),
}

/// Read + parse the dashboard's config file on demand.
fn read_config(path: &ConfigPath) -> Result<NixConfigFile, ConfigReadError> {
    let file_path = path.as_path();
    if !file_path.exists() {
        return Err(ConfigReadError::NotFound(file_path.to_path_buf()));
    }
    let source = std::fs::read_to_string(file_path)
        .map_err(|error| ConfigReadError::Io(file_path.to_path_buf(), error))?;
    NixConfigFile::parse(source).map_err(ConfigReadError::Parse)
}

/// One field edit: the attrpath plus its new value as a rendered
/// `NixValue`. Kept as raw source text so the caller decides
/// serialization.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigEdit {
    pub path: Vec<String>,
    pub source: String,
}

/// Save a set of edits to the config file. All-or-nothing: every edit
/// applies to one candidate file, re-parse validates the result, and only
/// then is the file replaced (temp-file + rename). A single failure leaves
/// the file byte-identical.
pub fn save_config(
    path: &ConfigPath,
    edits: &[ConfigEdit],
) -> Result<(), SaveError> {
    let mut candidate = read_config(path)?;
    for edit in edits {
        let path_refs: Vec<&str> = edit.path.iter().map(String::as_str).collect();
        candidate
            .set_attrpath(&path_refs, &edit.source)
            .map_err(|error| SaveError::Edit { path: edit.path.join("."), error })?;
    }
    write_atomic(path.as_path(), candidate.to_source())
}

/// Replace a file atomically: write to a temp sibling, then rename over
/// the target. A crash mid-write leaves the original intact.
fn write_atomic(path: &std::path::Path, contents: &str) -> Result<(), SaveError> {
    let parent = path.parent().ok_or_else(|| {
        SaveError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "config path has no parent directory",
        ))
    })?;
    let tmp = parent.join(format!(
        ".cococoir-dashboard.{}.tmp",
        uuid::Uuid::new_v4()
    ));
    std::fs::write(&tmp, contents)
        .map_err(|error| SaveError::Io(error))?;
    std::fs::rename(&tmp, path).map_err(|error| SaveError::Io(error))
}

/// Failures from a save. The file is never modified on error.
#[derive(Debug, thiserror::Error)]
pub enum SaveError {
    #[error(transparent)]
    Read(#[from] ConfigReadError),
    #[error("edit failed at {path}: {error}")]
    Edit { path: String, error: SetError },
    #[error("write failed: {0}")]
    Io(#[source] std::io::Error),
}

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

/// Build the editor page from the extracted config. `config_error`
/// surfaces a read failure; otherwise the page shows the current values.
fn editor_page(
    config: &CococoirConfig,
    config_error: Option<String>,
    saved: bool,
    save_error: Option<String>,
) -> Response {
    let services = crate::dashboard::nix_config_parser::SERVICE_LIST
        .iter()
        .map(|service| EditorServiceProps {
            nixname: service.nixname.to_string(),
            display_name: service.display_name,
            description: service.description,
            enabled: config.services_enabled.get(service.nixname).copied().unwrap_or(false),
            declared: config.services_enabled.contains_key(service.nixname),
        })
        .collect();

    let users = config
        .users
        .values()
        .map(|user| EditorUserProps {
            username: user.username.clone(),
            is_admin: user.is_admin(),
            groups: user.groups.iter().cloned().collect(),
            has_password: user.hashed_password.is_some(),
            groups_declared: user.groups_declared,
        })
        .collect();

    let props = EditorPageProps {
        hostname: config.hostname.clone().unwrap_or_default(),
        base_domain: config.root_domain.clone().unwrap_or_default(),
        services,
        users,
        config_error,
        saved,
        save_error,
    };
    Html(component::<EditorPage>(props).to_html())
        .with_status(StatusCode::OK)
        .into_response()
}

fn editor_state(path: &ConfigPath) -> (CococoirConfig, Option<String>) {
    match read_config(path) {
        Ok(file) => {
            let config = CococoirConfig::extract(&file, &ConfigSchema::default());
            (config, None)
        }
        Err(error) => (CococoirConfig::default(), Some(error.to_string())),
    }
}

#[handler]
async fn index(Data(config_path): Data<&ConfigPath>) -> Response {
    let (config, error) = editor_state(config_path);
    editor_page(&config, error, false, None)
}

/// Form fields the editor submits. `svc_<name>` is present only when the
/// checkbox is checked; `groups_<user>` is a comma/space-separated list.
#[derive(Debug, Default, Deserialize)]
struct EditorForm {
    hostname: Option<String>,
    base_domain: Option<String>,
    #[serde(flatten)]
    dynamic: std::collections::HashMap<String, String>,
}

impl EditorForm {
    fn service_checked(&self, nixname: &str) -> bool {
        self.dynamic
            .get(&format!("svc_{nixname}"))
            .is_some_and(|v| v == "true")
    }

    fn user_groups(&self, username: &str) -> Option<String> {
        self.dynamic.get(&format!("groups_{username}")).cloned()
    }
}

/// Build the edits for a save from the submitted form, skipping fields
/// the parser cannot edit (undeclared service enables, undeclared user
/// groups) — those stay manual edits, matching the read-only UI.
fn build_edits(config: &CococoirConfig, form: &EditorForm) -> Vec<ConfigEdit> {
    let mut edits = Vec::new();

    if let Some(hostname) = &form.hostname {
        if config.hostname.is_some() {
            edits.push(ConfigEdit {
                path: vec!["networking".into(), "hostName".into()],
                source: NixValue::Str(hostname.clone()).to_source(),
            });
        }
    }
    if let Some(domain) = &form.base_domain {
        if config.root_domain.is_some() {
            edits.push(ConfigEdit {
                path: vec!["cococoir".into(), "baseDomain".into()],
                source: NixValue::Str(domain.clone()).to_source(),
            });
        }
    }

    for service in crate::dashboard::nix_config_parser::SERVICE_LIST {
        if config.services_enabled.contains_key(service.nixname) {
            let enabled = form.service_checked(service.nixname);
            edits.push(ConfigEdit {
                path: vec!["cococoir".into(), "services".into(), service.nixname.into(), "enable".into()],
                source: NixValue::Bool(enabled).to_source(),
            });
        }
    }

    for (username, user) in &config.users {
        if let Some(groups_text) = form.user_groups(username) {
            if user.groups_declared {
                let groups: Vec<String> = groups_text
                    .split(|c: char| c.is_whitespace() || c == ',')
                    .filter(|g| !g.is_empty())
                    .map(str::to_string)
                    .collect();
                edits.push(ConfigEdit {
                    path: vec!["users".into(), "users".into(), username.clone(), "groups".into()],
                    source: NixValue::StrList(groups).to_source(),
                });
            }
        }
    }

    edits
}

#[handler]
async fn index_save(
    Data(config_path): Data<&ConfigPath>,
    Form(form): Form<EditorForm>,
) -> Response {
    let (config, read_error) = editor_state(config_path);
    if let Some(error) = read_error {
        return editor_page(&config, Some(error), false, None);
    }
    let edits = build_edits(&config, &form);
    match save_config(config_path, &edits) {
        Ok(()) => {
            let (saved_config, read_error) = editor_state(config_path);
            editor_page(&saved_config, read_error, true, None)
        }
        Err(error) => {
            tracing::warn!(error = %error, "config save rejected");
            editor_page(&config, None, false, Some(error.to_string()))
        }
    }
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

fn app(db: Db, auth: AuthMode, config_path: ConfigPath) -> impl Endpoint {
    let gate_auth = auth.clone();
    let protected = Route::new()
        .at("/", get(index).post(index_save))
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
        .data(config_path)
}

pub async fn dashboard_entry() -> Result<(), std::io::Error> {
    let db = Db::open().await.map_err(|error| {
        tracing::error!(error = %error, "dashboard database failed to open");
        std::io::Error::other("dashboard database failed to open")
    })?;
    let config_path = ConfigPath::resolve();
    tracing::info!(config = %config_path.as_path().display(), "dashboard config path");
    Server::new(TcpListener::bind("0.0.0.0:3000"))
        .run(app(db, AuthMode::current().clone(), config_path))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use poem::test::TestClient;

    fn test_config_path() -> ConfigPath {
        ConfigPath(PathBuf::from("/nonexistent/dashboard.nix"))
    }

    fn test_auth() -> AuthMode {
        AuthMode::Password(auth::AdminConfig {
            password_hash: "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W".to_string(),
        })
    }

    #[tokio::test]
    async fn hello_renders_and_counter_persists() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev, test_config_path()));
        let first = client.get("/hello/alice").send().await;
        first.assert_status(StatusCode::OK);
        let first_body = first.0.into_body().into_string().await.expect("utf8 body");
        assert!(first_body.contains("alice"));
        assert!(first_body.contains(" 1 times."));
        assert!(first_body.contains("data-theme=\"dark\""));
        assert!(first_body.contains("daisyui@5"));
        let second = client.get("/hello/alice").send().await;
        let second_body = second.0.into_body().into_string().await.expect("utf8 body");
        assert!(second_body.contains(" 2 times."));
    }

    #[tokio::test]
    async fn session_endpoints_round_trip() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev, test_config_path()));
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
        let client = TestClient::new(app(db, AuthMode::Dev, test_config_path()));
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
        let client = TestClient::new(app(db, test_auth(), test_config_path()));
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
        let client = TestClient::new(app(db, test_auth(), test_config_path()));
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
        let client = TestClient::new(app(db, test_auth(), test_config_path()));
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
        let client = TestClient::new(app(db, test_auth(), test_config_path()));
        let response = client.get("/auth/login").send().await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Sign in to the admin dashboard"));
        assert!(body.contains("btn btn-primary"));
        assert!(body.contains("data-theme=\"dark\""));
    }

    #[tokio::test]
    async fn login_grants_session_with_correct_password() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path()));
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
        let client = TestClient::new(app(db, test_auth(), test_config_path()));
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
        let client = TestClient::new(app(db, AuthMode::Dev, test_config_path()));
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
        let client = TestClient::new(app(db.clone(), test_auth(), test_config_path()));
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

    #[test]
    fn config_path_resolves_from_env_with_fallback() {
        // Fallback when unset.
        unsafe {
            std::env::remove_var("COCOCOIR_CONFIG_PATH");
        }
        assert_eq!(
            ConfigPath::resolve().as_path(),
            PathBuf::from("nixosConfigurations/dashboard.nix")
        );

        // Explicit value wins.
        unsafe {
            std::env::set_var("COCOCOIR_CONFIG_PATH", "/tmp/coco.nix");
        }
        let resolved = ConfigPath::resolve();
        assert_eq!(resolved.as_path(), PathBuf::from("/tmp/coco.nix"));
        unsafe {
            std::env::remove_var("COCOCOIR_CONFIG_PATH");
        }
    }

    #[test]
    fn read_config_missing_file_is_not_found() {
        let path = ConfigPath(PathBuf::from("/nonexistent/coco.nix"));
        assert!(matches!(read_config(&path), Err(ConfigReadError::NotFound(_))));
    }

    #[test]
    fn read_config_unparseable_file_is_parse_error() {
        let dir = std::env::temp_dir().join(format!("coco-read-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        std::fs::write(path.as_path(), "cococoir = {").expect("write garbage");
        assert!(matches!(read_config(&path), Err(ConfigReadError::Parse(_))));
    }

    #[test]
    fn read_config_valid_file_parses() {
        let dir = std::env::temp_dir().join(format!("coco-read-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        std::fs::write(path.as_path(), "{ networking.hostName = \"vmtest\"; }")
            .expect("write config");
        let file = read_config(&path).expect("reads and parses");
        assert_eq!(file.to_source().trim(), "{ networking.hostName = \"vmtest\"; }");
    }

    #[test]
    fn save_config_writes_only_the_edited_span() {
        let dir = std::env::temp_dir().join(format!("coco-save-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        let original = "{ cococoir.baseDomain = \"vmtest.local\"; networking.hostName = \"vmtest\"; }\n";
        std::fs::write(path.as_path(), original).expect("write config");

        let edits = vec![ConfigEdit {
            path: vec!["networking".into(), "hostName".into()],
            source: "\"other\"".to_string(),
        }];
        save_config(&path, &edits).expect("save succeeds");

        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(written.contains("cococoir.baseDomain = \"vmtest.local\""));
        assert!(written.contains("networking.hostName = \"other\""));
        assert!(!written.contains("networking.hostName = \"vmtest\""));
    }

    #[test]
    fn save_config_all_or_nothing_on_bad_edit() {
        let dir = std::env::temp_dir().join(format!("coco-save-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        let original = "{ networking.hostName = \"vmtest\"; }\n";
        std::fs::write(path.as_path(), original).expect("write config");

        let edits = vec![
            ConfigEdit {
                path: vec!["networking".into(), "hostName".into()],
                source: "\"changed\"".to_string(),
            },
            ConfigEdit {
                path: vec!["cococoir".into(), "nonexistent".into()],
                source: "true".to_string(),
            },
        ];
        let result = save_config(&path, &edits);
        assert!(result.is_err(), "missing path must fail the whole save");
        assert_eq!(
            std::fs::read_to_string(path.as_path()).expect("read back"),
            original,
            "failed save must leave the file byte-identical"
        );
    }

    #[test]
    fn save_config_rejects_unparseable_value() {
        let dir = std::env::temp_dir().join(format!("coco-save-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        let original = "{ networking.hostName = \"vmtest\"; }\n";
        std::fs::write(path.as_path(), original).expect("write config");

        let edits = vec![ConfigEdit {
            path: vec!["networking".into(), "hostName".into()],
            source: "}".to_string(),
        }];
        assert!(save_config(&path, &edits).is_err());
        assert_eq!(
            std::fs::read_to_string(path.as_path()).expect("read back"),
            original,
            "invalid value must not touch the file"
        );
    }

    fn temp_config(contents: &str) -> ConfigPath {
        let dir = std::env::temp_dir().join(format!("coco-ui-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        std::fs::write(path.as_path(), contents).expect("write config");
        path
    }

    const EDITOR_FIXTURE: &str = r#"{
  cococoir.baseDomain = "vmtest.local";
  networking.hostName = "vmtest";
  cococoir.services.jellyfin.enable = true;
  cococoir.services.cryptpad.enable = false;
  users.users.nicole = {
    groups = [ "wheel" "storage" ];
  };
}
"#;

    #[tokio::test]
    async fn editor_renders_known_fields() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev, temp_config(EDITOR_FIXTURE)));
        let response = client.get("/").send().await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("value=\"vmtest\""));
        assert!(body.contains("value=\"vmtest.local\""));
        assert!(body.contains("name=\"svc_jellyfin\""));
        assert!(body.contains("name=\"svc_cryptpad\""));
        assert!(body.contains("name=\"groups_nicole\""));
        assert!(body.contains("value=\"storage, wheel\""), "BTreeSet sorts groups");
        assert!(!body.contains("Could not load the config file"), "fixture must parse");
    }

    #[tokio::test]
    async fn editor_shows_read_error_banner_on_missing_file() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev, test_config_path()));
        let response = client.get("/").send().await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Could not load the config file"));
    }

    #[tokio::test]
    async fn editor_save_writes_file_and_flashes_saved() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = TestClient::new(app(db, AuthMode::Dev, path.clone()));
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=other&base_domain=home.arpa&svc_jellyfin=true&svc_cryptpad=true&groups_nicole=wheel")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Saved."));

        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(written.contains("networking.hostName = \"other\""));
        assert!(written.contains("cococoir.baseDomain = \"home.arpa\""));
        assert!(written.contains("cococoir.services.cryptpad.enable = true"));
        assert!(written.contains("cococoir.services.jellyfin.enable = true"));
        assert!(written.contains("groups = [ \"wheel\" ]"), "groups replaced: {written}");
    }

    #[tokio::test]
    async fn editor_save_unchecks_a_service() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = TestClient::new(app(db, AuthMode::Dev, path.clone()));
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=vmtest&base_domain=vmtest.local&svc_jellyfin=true&groups_nicole=wheel storage")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(
            written.contains("cococoir.services.cryptpad.enable = false"),
            "unchecked service must save as false: {written}"
        );
    }

    #[tokio::test]
    async fn editor_save_ignores_undeclared_fields() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = TestClient::new(app(db, AuthMode::Dev, path.clone()));
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            // sonarr has no enable binding in the fixture; submitting it must not
            // fail the save (the parser cannot insert bindings).
            .body("hostname=vmtest&base_domain=vmtest.local&svc_jellyfin=true&svc_sonarr=true&groups_nicole=wheel")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Saved."));
    }

    #[tokio::test]
    async fn editor_save_missing_file_shows_error_not_panic() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, AuthMode::Dev, test_config_path()));
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=other")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response.0.into_body().into_string().await.expect("utf8 body");
        assert!(body.contains("Could not load the config file"));
    }
}
