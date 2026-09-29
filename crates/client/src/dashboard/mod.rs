pub mod auth;
pub mod components;
mod db;
pub mod nix_config_parser;

pub use auth::AdminConfig;
pub use db::Db;

use crate::dashboard::auth::{
    clear_session_cookie_header, gate_request, read_cookie, session_cookie_header, verify_password,
    SESSION_COOKIE,
};
use crate::dashboard::components::{
    ClaimView, EditorPage, EditorPageProps, EditorServiceProps, EditorUserProps, LoginPage,
    LoginPageProps,
};
use crate::dashboard::nix_config_parser::{
    ConfigSchema, FortressConfig, NixConfigFile, NixParseError, NixValue, SetError,
};
use momenta::prelude::*;
use poem::{
    get, handler, post,
    http::{header, StatusCode},
    listener::TcpListener,
    web::{Data, Form, Html},
    Endpoint, EndpointExt, IntoResponse, Request, Response, Route, Server,
};
use serde::Deserialize;
use std::path::PathBuf;

/// The claim lifecycle the Remote access card mirrors. "Claimed" is
/// derived from the persisted enrollment (it survives restarts); this
/// covers the states that live only while the process runs.
#[derive(Debug, Clone, Default, PartialEq)]
pub enum ClaimState {
    #[default]
    Unclaimed,
    /// A claim is dialing the edge / waiting for the owner's approval.
    Awaiting,
    Failed { message: String },
}

/// What the dashboard needs to drive claims: the live state and the
/// action that starts one. The action owns the edge client, the
/// enrollment paths and the post-claim restart — the dashboard never
/// touches the enrollment wire itself.
#[derive(Clone)]
pub struct ClaimSupport {
    pub state: std::sync::Arc<std::sync::Mutex<ClaimState>>,
    pub tunnel_state_path: PathBuf,
    pub spawn_claim: std::sync::Arc<dyn Fn(String) + Send + Sync>,
}

/// The dashboard-edited Nix config file. Resolved once from the
/// `FORTRESS_CONFIG_PATH` env var; falls back to the repo-relative
/// `nixosConfigurations/dashboard.nix` for the dev loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigPath(PathBuf);

impl ConfigPath {
    pub fn resolve() -> Self {
        Self(
            std::env::var_os("FORTRESS_CONFIG_PATH")
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
pub fn save_config(path: &ConfigPath, edits: &[ConfigEdit]) -> Result<(), SaveError> {
    let mut candidate = read_config(path)?;
    for edit in edits {
        let path_refs: Vec<&str> = edit.path.iter().map(String::as_str).collect();
        candidate
            .set_attrpath(&path_refs, &edit.source)
            .map_err(|error| SaveError::Edit {
                path: edit.path.join("."),
                error,
            })?;
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
    let tmp = parent.join(format!(".fortress-dashboard.{}.tmp", uuid::Uuid::new_v4()));
    std::fs::write(&tmp, contents).map_err(|error| SaveError::Io(error))?;
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

/// Build the editor page from the extracted config. `config_error`
/// surfaces a read failure; otherwise the page shows the current values.
fn editor_page(
    config: &FortressConfig,
    config_error: Option<String>,
    saved: bool,
    save_error: Option<String>,
    remote: ClaimView,
) -> Response {
    let services = crate::dashboard::nix_config_parser::SERVICE_LIST
        .iter()
        .map(|service| EditorServiceProps {
            nixname: service.nixname.to_string(),
            display_name: service.display_name,
            description: service.description,
            enabled: config
                .services_enabled
                .get(service.nixname)
                .copied()
                .unwrap_or(false),
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
        remote,
    };
    Html(component::<EditorPage>(props).to_html())
        .with_status(StatusCode::OK)
        .into_response()
}

fn editor_state(path: &ConfigPath) -> (FortressConfig, Option<String>) {
    match read_config(path) {
        Ok(file) => {
            let config = FortressConfig::extract(&file, &ConfigSchema::default());
            (config, None)
        }
        Err(error) => (FortressConfig::default(), Some(error.to_string())),
    }
}

#[handler]
async fn index(
    Data(config_path): Data<&ConfigPath>,
    Data(claim): Data<&ClaimSupport>,
) -> Response {
    let (config, error) = editor_state(config_path);
    editor_page(&config, error, false, None, remote_view(claim))
}

/// Form fields for the claim: the invite link the owner generated.
#[derive(Debug, Deserialize)]
struct ClaimForm {
    invite_url: Option<String>,
}

/// Start a claim from the pasted invite link. Validation happens here
/// (a malformed link must not reach the edge client); the heavy
/// lifting — enroll, persist, restart — is the spawned action.
#[handler]
async fn claim_submit(Data(claim): Data<&ClaimSupport>, Form(form): Form<ClaimForm>) -> Response {
    let url = form.invite_url.unwrap_or_default().trim().to_string();
    {
        let mut state = claim.state.lock().unwrap();
        if crate::pairing::persisted_tunnel_state(&claim.tunnel_state_path).is_some() {
            *state = ClaimState::Failed {
                message: "This box is already claimed.".to_string(),
            };
            return see_other("/");
        }
        if *state == ClaimState::Awaiting {
            return see_other("/");
        }
        match crate::pairing::InviteConfig::from_url(&url) {
            Ok(_) => *state = ClaimState::Awaiting,
            Err(err) => {
                *state = ClaimState::Failed {
                    message: format!("That is not an invite link: {err}"),
                };
                return see_other("/");
            }
        }
    }
    (claim.spawn_claim)(url);
    see_other("/")
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

/// Build the edits for a save from the submitted form.
///
/// A declared binding is always rewritten (the form submits the full
/// state of what it shows). An *undeclared* one is only created when the
/// customer checked it: ticking a box is an explicit act, leaving one
/// unticked is not, and inserting `enable = false` for every service the
/// customer never mentioned would litter their config with bindings that
/// just restate a module default.
fn build_edits(config: &FortressConfig, form: &EditorForm) -> Vec<ConfigEdit> {
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
                path: vec!["fortress".into(), "baseDomain".into()],
                source: NixValue::Str(domain.clone()).to_source(),
            });
        }
    }

    for service in crate::dashboard::nix_config_parser::SERVICE_LIST {
        let declared = config.services_enabled.contains_key(service.nixname);
        let enabled = form.service_checked(service.nixname);
        if !declared && !enabled {
            continue;
        }
        edits.push(ConfigEdit {
            path: vec![
                "fortress".into(),
                "services".into(),
                service.nixname.into(),
                "enable".into(),
            ],
            source: NixValue::Bool(enabled).to_source(),
        });
    }

    for (username, user) in &config.users {
        if let Some(groups_text) = form.user_groups(username) {
            let groups: Vec<String> = groups_text
                .split(|c: char| c.is_whitespace() || c == ',')
                .filter(|g| !g.is_empty())
                .map(str::to_string)
                .collect();
            // Same rule as the service toggles: never create a binding
            // that only restates an empty default.
            if !user.groups_declared && groups.is_empty() {
                continue;
            }
            edits.push(ConfigEdit {
                path: vec![
                    "users".into(),
                    "users".into(),
                    username.clone(),
                    "groups".into(),
                ],
                source: NixValue::StrList(groups).to_source(),
            });
        }
    }

    edits
}

/// Redirect response for POST-then-GET form flows.
fn see_other(location: &str) -> Response {
    Response::builder()
        .status(StatusCode::SEE_OTHER)
        .header(header::LOCATION, location)
        .finish()
}

/// The Remote access view: a persisted enrollment wins (it survives
/// restarts); otherwise the live claim state.
fn remote_view(claim: &ClaimSupport) -> ClaimView {
    if let Some(persisted) = crate::pairing::persisted_tunnel_state(&claim.tunnel_state_path) {
        return ClaimView::Claimed {
            hostname: persisted.hostname,
        };
    }
    match &*claim.state.lock().unwrap() {
        ClaimState::Unclaimed => ClaimView::Unclaimed,
        ClaimState::Awaiting => ClaimView::Awaiting,
        ClaimState::Failed { message } => ClaimView::Failed {
            message: message.clone(),
        },
    }
}

#[handler]
async fn index_save(
    Data(config_path): Data<&ConfigPath>,
    Data(claim): Data<&ClaimSupport>,
    Form(form): Form<EditorForm>,
) -> Response {
    let remote = remote_view(claim);
    let (config, read_error) = editor_state(config_path);
    if let Some(error) = read_error {
        return editor_page(&config, Some(error), false, None, remote);
    }
    let edits = build_edits(&config, &form);
    match save_config(config_path, &edits) {
        Ok(()) => {
            let (saved_config, read_error) = editor_state(config_path);
            editor_page(&saved_config, read_error, true, None, remote)
        }
        Err(error) => {
            tracing::warn!(error = %error, "config save rejected");
            editor_page(&config, None, false, Some(error.to_string()), remote)
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
async fn login_page_get() -> Response {
    login_page(false)
}

#[handler]
async fn login_page_post(
    Data(db): Data<&Db>,
    Data(auth): Data<&AdminConfig>,
    Form(form): Form<LoginForm>,
) -> Response {
    // A missing password field fails the same way as a wrong one.
    let Some(password) = form.password.as_deref() else {
        return login_page(true);
    };
    if !verify_password(password, &auth.password_hash) {
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

fn app(db: Db, auth: AdminConfig, config_path: ConfigPath, claim: ClaimSupport) -> impl Endpoint {
    let gate_auth = auth.clone();
    // Everything except the login form sits behind the session gate —
    // including logout, so the "exactly one public page" property stays
    // true and a stray route can't slip outside it unnoticed.
    let protected = Route::new()
        .at("/", get(index).post(index_save))
        .at("/claim", post(claim_submit))
        .at("/auth/logout", get(logout))
        .around(move |ep, req| {
            let auth = gate_auth.clone();
            async move { gate_request(&auth, ep, req).await }
        });

    Route::new()
        .at("/auth/login", get(login_page_get).post(login_page_post))
        .nest("/", protected)
        .data(db)
        .data(auth)
        .data(config_path)
        .data(claim)
}

pub async fn serve(
    db: Db,
    auth: AdminConfig,
    config_path: ConfigPath,
    addr: &str,
    shutdown: tokio::sync::watch::Receiver<bool>,
    claim: ClaimSupport,
) -> Result<(), std::io::Error> {
    Server::new(TcpListener::bind(addr))
        .run_with_graceful_shutdown(
            app(db, auth, config_path, claim),
            async move {
                let mut shutdown = shutdown;
                let _ = shutdown.wait_for(|v| *v).await;
            },
            None,
        )
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dashboard::db::DbError;
    use poem::test::TestClient;

    fn test_config_path() -> ConfigPath {
        ConfigPath(PathBuf::from("/nonexistent/dashboard.nix"))
    }

    fn test_auth() -> AdminConfig {
        AdminConfig {
            password_hash: "$2b$10$1fpkGdW2JfbsNSx9a.HM6.zNjHempOqsubMvxPoq9fOydOs18HG.W"
                .to_string(),
        }
    }

    fn test_claim_support() -> ClaimSupport {
        ClaimSupport {
            state: std::sync::Arc::new(std::sync::Mutex::new(ClaimState::Unclaimed)),
            tunnel_state_path: PathBuf::from("/nonexistent/tunnel.json"),
            spawn_claim: std::sync::Arc::new(|_| {}),
        }
    }

    fn recording_claim_support(
        tunnel_state_path: PathBuf,
    ) -> (ClaimSupport, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let spawned: std::sync::Arc<std::sync::Mutex<Vec<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let record = spawned.clone();
        let support = ClaimSupport {
            state: std::sync::Arc::new(std::sync::Mutex::new(ClaimState::Unclaimed)),
            tunnel_state_path,
            spawn_claim: std::sync::Arc::new(move |url| record.lock().unwrap().push(url)),
        };
        (support, spawned)
    }

    /// A client whose requests carry a valid admin session, so the
    /// tests exercise the editor rather than the login gate. There is no
    /// way to skip the gate — so every
    /// page test logs in first.
    async fn authed_client(db: Db, config_path: ConfigPath) -> TestClient<impl Endpoint> {
        let token = db.create_session("admin").await.expect("create session");
        TestClient::new(app(db, test_auth(), config_path, test_claim_support()))
            .default_header(header::COOKIE, format!("{SESSION_COOKIE}={token}"))
    }

    #[tokio::test]
    async fn gate_bounces_unauthenticated_page_loads() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
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

    /// Tripwire: there is no unauthenticated surface. Exactly one page
    /// is public — the login form — and everything else bounces a
    /// request with no session cookie, so a future route added outside
    /// the gated `Route` cannot silently ship an open admin UI. This is
    /// the regression guard for the `AuthMode::Dev` hole.
    #[tokio::test]
    async fn every_page_route_requires_a_session() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));

        let public = client.get("/auth/login").send().await;
        public.assert_status(StatusCode::OK);

        for path in ["/", "/auth/logout"] {
            let bounced = client.get(path).send().await;
            assert_eq!(
                bounced.0.status(),
                StatusCode::SEE_OTHER,
                "{path} must require a session"
            );
            let location = bounced
                .0
                .headers()
                .get(header::LOCATION)
                .expect("redirect location")
                .to_str()
                .unwrap();
            assert_eq!(location, "/auth/login", "{path} must bounce to login");
        }
    }

    #[tokio::test]
    async fn gate_redirects_htmx_with_hx_header() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
        let bounced = client
            .get("/")
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
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
        let response = client
            .get("/")
            .header(header::COOKIE, format!("fortress_session={token}"))
            .send()
            .await;
        response.assert_status(StatusCode::OK);
    }

    #[tokio::test]
    async fn login_page_renders_in_password_mode() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
        let response = client.get("/auth/login").send().await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("Sign in to the admin dashboard"));
        assert!(body.contains("btn-zine"), "zine submit button");
        assert!(body.contains(r#"class="zine app""#), "app-mode shell");
    }

    /// Tripwire: dashboard pages inline their assets, never reference a
    /// third-party origin at runtime.
    #[test]
    fn dashboard_pages_have_no_external_asset_origins() {
        let login_html = component::<LoginPage>(LoginPageProps { error: false }).to_html();
        let editor_html = component::<EditorPage>(EditorPageProps {
            hostname: "living-room".into(),
            base_domain: "x.example.com".into(),
            services: vec![],
            users: vec![],
            config_error: None,
            saved: false,
            save_error: None,
            remote: ClaimView::Unclaimed,
        })
        .to_html();
        for (name, html) in [("login", login_html), ("editor", editor_html)] {
            for banned in [
                "<script src=\"http",
                "<link rel=\"stylesheet\" href=\"http",
                "<img src=\"http",
                "<iframe src=\"http",
                "<link href=\"http",
                "url(http",
                "cdn.jsdelivr",
                "cdnjs.cloudflare.com",
                "daisyui",
            ] {
                assert!(
                    !html.contains(banned),
                    "{name} references a third-party origin: {banned}"
                );
            }
            assert!(
                html.contains("--red: #d02a1e"),
                "{name} must carry the zine tokens"
            );
        }
    }

    #[tokio::test]
    async fn login_grants_session_with_correct_password() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
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
        assert!(set_cookie.contains("fortress_session="));
        let token = set_cookie
            .split("fortress_session=")
            .nth(1)
            .and_then(|rest| rest.split(';').next())
            .expect("cookie token");
        let gate = client
            .get("/")
            .header(header::COOKIE, format!("fortress_session={token}"))
            .send()
            .await;
        gate.assert_status(StatusCode::OK);
    }

    #[tokio::test]
    async fn login_rejects_wrong_password() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
        let response = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body("password=hunter2")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("Incorrect password."));
        let bounced = client.get("/").send().await;
        bounced.assert_status(StatusCode::SEE_OTHER);
    }

    #[tokio::test]
    async fn logout_deletes_session_and_clears_cookie() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let token = db.create_session("bob").await.expect("create session");
        let client = TestClient::new(app(
            db.clone(),
            test_auth(),
            test_config_path(),
            test_claim_support(),
        ));
        let response = client
            .get("/auth/logout")
            .header(header::COOKIE, format!("fortress_session={token}"))
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
            std::env::remove_var("FORTRESS_CONFIG_PATH");
        }
        assert_eq!(
            ConfigPath::resolve().as_path(),
            PathBuf::from("nixosConfigurations/dashboard.nix")
        );

        // Explicit value wins.
        unsafe {
            std::env::set_var("FORTRESS_CONFIG_PATH", "/tmp/coco.nix");
        }
        let resolved = ConfigPath::resolve();
        assert_eq!(resolved.as_path(), PathBuf::from("/tmp/coco.nix"));
        unsafe {
            std::env::remove_var("FORTRESS_CONFIG_PATH");
        }
    }

    #[test]
    fn read_config_missing_file_is_not_found() {
        let path = ConfigPath(PathBuf::from("/nonexistent/coco.nix"));
        assert!(matches!(
            read_config(&path),
            Err(ConfigReadError::NotFound(_))
        ));
    }

    #[test]
    fn read_config_unparseable_file_is_parse_error() {
        let dir = std::env::temp_dir().join(format!("coco-read-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        std::fs::write(path.as_path(), "fortress = {").expect("write garbage");
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
        assert_eq!(
            file.to_source().trim(),
            "{ networking.hostName = \"vmtest\"; }"
        );
    }

    #[test]
    fn save_config_writes_only_the_edited_span() {
        let dir = std::env::temp_dir().join(format!("coco-save-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = ConfigPath(dir.join("dashboard.nix"));
        let original =
            "{ fortress.baseDomain = \"vmtest.local\"; networking.hostName = \"vmtest\"; }\n";
        std::fs::write(path.as_path(), original).expect("write config");

        let edits = vec![ConfigEdit {
            path: vec!["networking".into(), "hostName".into()],
            source: "\"other\"".to_string(),
        }];
        save_config(&path, &edits).expect("save succeeds");

        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(written.contains("fortress.baseDomain = \"vmtest.local\""));
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
            // Blocked, not merely missing: `networking` is a namespace
            // here (the file binds `networking.hostName`), so assigning
            // to it would collide. One bad edit must sink the whole save.
            ConfigEdit {
                path: vec!["networking".into()],
                source: "5".to_string(),
            },
        ];
        let result = save_config(&path, &edits);
        assert!(result.is_err(), "blocked path must fail the whole save");
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
  fortress.baseDomain = "vmtest.local";
  networking.hostName = "vmtest";
  fortress.services.jellyfin.enable = true;
  fortress.services.cryptpad.enable = false;
  users.users.nicole = {
    groups = [ "wheel" "storage" ];
  };
}
"#;

    #[tokio::test]
    async fn editor_renders_known_fields() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = authed_client(db, temp_config(EDITOR_FIXTURE)).await;
        let response = client.get("/").send().await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("value=\"vmtest\""));
        assert!(body.contains("value=\"vmtest.local\""));
        assert!(body.contains("name=\"svc_jellyfin\""));
        assert!(body.contains("name=\"svc_cryptpad\""));
        assert!(body.contains("name=\"groups_nicole\""));
        assert!(
            body.contains("value=\"storage, wheel\""),
            "BTreeSet sorts groups"
        );
        assert!(
            !body.contains("Could not load the config file"),
            "fixture must parse"
        );
    }

    #[tokio::test]
    async fn editor_shows_read_error_banner_on_missing_file() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = authed_client(db, test_config_path()).await;
        let response = client.get("/").send().await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("Could not load the config file"));
    }

    #[tokio::test]
    async fn editor_save_writes_file_and_flashes_saved() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = authed_client(db, path.clone()).await;
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=other&base_domain=home.arpa&svc_jellyfin=true&svc_cryptpad=true&groups_nicole=wheel")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("Saved."));

        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(written.contains("networking.hostName = \"other\""));
        assert!(written.contains("fortress.baseDomain = \"home.arpa\""));
        assert!(written.contains("fortress.services.cryptpad.enable = true"));
        assert!(written.contains("fortress.services.jellyfin.enable = true"));
        assert!(
            written.contains("groups = [ \"wheel\" ]"),
            "groups replaced: {written}"
        );
    }

    #[tokio::test]
    async fn editor_save_unchecks_a_service() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = authed_client(db, path.clone()).await;
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=vmtest&base_domain=vmtest.local&svc_jellyfin=true&groups_nicole=wheel storage")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(
            written.contains("fortress.services.cryptpad.enable = false"),
            "unchecked service must save as false: {written}"
        );
    }

    #[tokio::test]
    async fn editor_save_inserts_a_checked_undeclared_service() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = authed_client(db, path.clone()).await;
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            // forgejo has no `enable` binding in the fixture; checking it
            // must CREATE one rather than silently dropping the edit.
            .body("hostname=vmtest&base_domain=vmtest.local&svc_jellyfin=true&svc_forgejo=true&groups_nicole=wheel")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("Saved."));

        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(
            written.contains("fortress.services.forgejo.enable = true;")
                || written.contains("services.forgejo.enable = true;"),
            "checked service must gain a binding: {written}"
        );
    }

    /// The other half of the insert policy: an untouched, undeclared
    /// service must NOT grow a binding that restates a module default.
    #[tokio::test]
    async fn editor_save_skips_unchecked_undeclared_services() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let path = temp_config(EDITOR_FIXTURE);
        let client = authed_client(db, path.clone()).await;
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=vmtest&base_domain=vmtest.local&svc_jellyfin=true&groups_nicole=wheel")
            .send()
            .await;
        response.assert_status(StatusCode::OK);

        let written = std::fs::read_to_string(path.as_path()).expect("read back");
        assert!(
            !written.contains("forgejo") && !written.contains("media"),
            "unchecked service must not be written: {written}"
        );
    }

    #[tokio::test]
    async fn editor_save_missing_file_shows_error_not_panic() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = authed_client(db, test_config_path()).await;
        let response = client
            .post("/")
            .content_type("application/x-www-form-urlencoded")
            .body("hostname=other")
            .send()
            .await;
        response.assert_status(StatusCode::OK);
        let body = response
            .0
            .into_body()
            .into_string()
            .await
            .expect("utf8 body");
        assert!(body.contains("Could not load the config file"));
    }

    /// The claim form is the box's entry into remote access: it shows
    /// when nothing is enrolled, the pasted link is validated before
    /// any spawn, and the card tells the truth while a claim runs.
    #[tokio::test]
    async fn claim_form_validates_and_drives_the_state_surfaces() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let dir = tempfile::tempdir().unwrap();
        let (claim, spawned) = recording_claim_support(dir.path().join("tunnel.json"));
        let token = db.create_session("admin").await.expect("session");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), claim))
            .default_header(header::COOKIE, format!("{SESSION_COOKIE}={token}"));

        let body = client
            .get("/")
            .send()
            .await
            .0
            .into_body()
            .into_string()
            .await
            .unwrap();
        assert!(body.contains("Remote access"), "the card is on the dashboard: {body}");
        assert!(body.contains("not claimed"), "unclaimed state is labelled: {body}");
        assert!(body.contains(r#"action="/claim""#), "the form posts to /claim: {body}");
        assert!(body.contains("invite_url"), "the form takes the invite link: {body}");

        // A malformed link never reaches the spawn action.
        let resp = client
            .post("/claim")
            .content_type("application/x-www-form-urlencoded")
            .body("invite_url=not-a-url")
            .send()
            .await;
        resp.assert_status(StatusCode::SEE_OTHER);
        assert!(spawned.lock().unwrap().is_empty(), "garbage never spawns a claim");
        let body = client
            .get("/")
            .send()
            .await
            .0
            .into_body()
            .into_string()
            .await
            .unwrap();
        assert!(body.contains("not an invite link"), "the failure is explained: {body}");

        // A real link spawns the claim action and the card says so.
        let resp = client
            .post("/claim")
            .content_type("application/x-www-form-urlencoded")
            .body("invite_url=https://proletariat.tech/i/polluted-move-cheetah-apple")
            .send()
            .await;
        resp.assert_status(StatusCode::SEE_OTHER);
        assert_eq!(
            *spawned.lock().unwrap(),
            vec!["https://proletariat.tech/i/polluted-move-cheetah-apple".to_string()],
            "the claim action got the link"
        );
        let body = client
            .get("/")
            .send()
            .await
            .0
            .into_body()
            .into_string()
            .await
            .unwrap();
        assert!(body.contains("Waiting"), "the card reports the in-flight claim: {body}");
        assert!(!body.contains("invite_url"), "no second form while a claim runs: {body}");
    }

    /// A persisted enrollment IS the claimed state: the card names the
    /// machine's own domain and offers no form.
    #[tokio::test]
    async fn claimed_box_shows_its_domain_and_no_form() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("tunnel.json");
        let tunnel = crate::tunnel::TunnelConfig {
            iface: "wg0".to_string(),
            ip: "10.10.0.7".to_string(),
            prefix: 24,
            edge_pubkey: "k".to_string(),
            edge_endpoint: "edge.example.net:51820".to_string(),
            edge_allowed_ips: "10.10.0.0/24".to_string(),
            listen_port: 0,
        };
        crate::pairing::persist_tunnel_state(&state_path, &tunnel, "main.example.net")
            .expect("persist");
        let (claim, spawned) = recording_claim_support(state_path);
        let token = db.create_session("admin").await.expect("session");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), claim))
            .default_header(header::COOKIE, format!("{SESSION_COOKIE}={token}"));
        let body = client
            .get("/")
            .send()
            .await
            .0
            .into_body()
            .into_string()
            .await
            .unwrap();
        assert!(
            body.contains("https:&#x2F;&#x2F;main.example.net"),
            "the box names its own domain (momenta escapes / in text): {body}"
        );
        assert!(body.contains("claimed"), "the state is labelled: {body}");
        assert!(!body.contains("invite_url"), "a claimed box offers no claim form: {body}");
        let resp = client
            .post("/claim")
            .content_type("application/x-www-form-urlencoded")
            .body("invite_url=https://proletariat.tech/i/polluted-move-cheetah-apple")
            .send()
            .await;
        resp.assert_status(StatusCode::SEE_OTHER);
        assert!(spawned.lock().unwrap().is_empty(), "a claimed box cannot claim again");
    }

    /// The claim route sits behind the session gate like everything else.
    #[tokio::test]
    async fn claim_route_requires_a_session() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db, test_auth(), test_config_path(), test_claim_support()));
        let bounced = client
            .post("/claim")
            .content_type("application/x-www-form-urlencoded")
            .body("invite_url=x")
            .send()
            .await;
        bounced.assert_status(StatusCode::SEE_OTHER);
        assert_eq!(
            bounced
                .0
                .headers()
                .get(header::LOCATION)
                .unwrap()
                .to_str()
                .unwrap(),
            "/auth/login"
        );
    }
}
