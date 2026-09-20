//! The site crate, one dioxus fullstack surface: plain axum routes for
//! `/install.sh` and the markdown wiki (document-origin-only rendering
//! law), plus dioxus SSR for the stateful pages. The axum tier is
//! disabled when the client (`dx --platform web`) compiles with
//! `--no-default-features --features web`, since axum cannot run on
//! wasm.
use dioxus::prelude::*;

pub mod account;

#[component]
pub fn App() -> Element {
    rsx! {
        Router::<Route> {}
    }
}

#[derive(Clone, Routable, Debug, PartialEq)]
pub enum Route {
    #[route("/")]
    Home {},
    #[route("/register")]
    Register {},
    #[route("/login")]
    Login {},
}

/// Shared auth-page shell: the zine app column (narrow, centered).
fn auth_shell(children: Element) -> Element {
    rsx! {
        main {
            class: "mx-auto flex max-w-md flex-col gap-4 p-6",
            {children}
        }
    }
}

#[component]
pub fn Register() -> Element {
    let mut email = use_signal(String::new);
    let mut password = use_signal(String::new);
    let error = use_signal(|| None::<String>);
    let navigator = use_navigator();

    let submit = move |event: Event<FormData>| {
        event.prevent_default();
        let email = email();
        let password = password();
        let mut error = error;
        let navigator = navigator.clone();
        spawn(async move {
            match account::signup(email, password).await {
                Ok(account::SignupOutcome::Created) => {
                    error.set(None);
                    navigator.push(Route::Home {});
                }
                Ok(account::SignupOutcome::Error { message }) => error.set(Some(message)),
                Err(err) => error.set(Some(err.to_string())),
            }
        });
    };

    let banner = error().map(|message| {
        rsx! {
            div {
                role: "alert",
                class: "alert-zine",
                "{message}"
            }
        }
    });

    auth_shell(rsx! {
        div {
            class: "flex flex-col gap-4",
            h1 { class: "text-2xl font-black uppercase", "Create an account" }
            {banner}
            form {
                class: "flex flex-col gap-4",
                onsubmit: submit,
                label {
                    class: "block",
                    div { class: "tag dim mb-1", "Email" }
                    input {
                        class: "zine-input",
                        r#type: "email",
                        name: "email",
                        required: true,
                        value: email(),
                        oninput: move |event| email.set(event.value()),
                    }
                }
                label {
                    class: "block",
                    div { class: "tag dim mb-1", "Password" }
                    input {
                        class: "zine-input",
                        r#type: "password",
                        name: "password",
                        required: true,
                        value: password(),
                        oninput: move |event| password.set(event.value()),
                    }
                }
                button {
                    r#type: "submit",
                    class: "btn-zine btn-zine-red",
                    "Sign up"
                }
            }
            p { class: "text-sm dim", "Already have an account? " }
            a { class: "link-zine", href: "/login", "Log in" }
        }
    })
}

#[component]
pub fn Login() -> Element {
    let mut email = use_signal(String::new);
    let mut password = use_signal(String::new);
    let error = use_signal(|| None::<String>);
    let navigator = use_navigator();

    let submit = move |event: Event<FormData>| {
        event.prevent_default();
        let email = email();
        let password = password();
        let mut error = error;
        let navigator = navigator.clone();
        spawn(async move {
            match account::login(email, password).await {
                Ok(account::LoginOutcome::Ok) => {
                    error.set(None);
                    navigator.push(Route::Home {});
                }
                Ok(account::LoginOutcome::NeedsVerification { email }) => {
                    error.set(Some(format!("Verify {email} first — check your inbox for the confirmation link.")));
                }
                Ok(account::LoginOutcome::Error { message }) => error.set(Some(message)),
                Err(err) => error.set(Some(err.to_string())),
            }
        });
    };

    let banner = error().map(|message| {
        rsx! {
            div {
                role: "alert",
                class: "alert-zine",
                "{message}"
            }
        }
    });

    auth_shell(rsx! {
        div {
            class: "flex flex-col gap-4",
            h1 { class: "text-2xl font-black uppercase", "Log in" }
            {banner}
            form {
                class: "flex flex-col gap-4",
                onsubmit: submit,
                label {
                    class: "block",
                    div { class: "tag dim mb-1", "Email" }
                    input {
                        class: "zine-input",
                        r#type: "email",
                        name: "email",
                        required: true,
                        value: email(),
                        oninput: move |event| email.set(event.value()),
                    }
                }
                label {
                    class: "block",
                    div { class: "tag dim mb-1", "Password" }
                    input {
                        class: "zine-input",
                        r#type: "password",
                        name: "password",
                        required: true,
                        value: password(),
                        oninput: move |event| password.set(event.value()),
                    }
                }
                button {
                    r#type: "submit",
                    class: "btn-zine btn-zine-red",
                    "Log in"
                }
            }
            p { class: "text-sm dim" }
            a { class: "link-zine", href: "/forgot", "Forgot your password?" }
        }
    })
}

#[component]
pub fn Home() -> Element {
    // The landing is static marketing content, but the navbar + hero
    // CTA reflect the session — resolved through a server function so
    // SSR renders the right state and the client re-checks after
    // hydration.
    let session = use_server_future(account::current_session)?;
    let (logged_in, email) = match session.read().as_ref() {
        Some(Ok(account::SessionState::LoggedIn { email })) => (true, Some(email.clone())),
        _ => (false, None),
    };
    rsx! {
        div {
            dangerous_inner_html: fortress_web_ui::landing_html(
                &fortress_web_ui::LandingProps { logged_in, email },
            ),
        }
    }
}

pub fn doc_css() -> &'static str { DOC_CSS }

pub const DOC_CSS: &str = r#"
  :root { --paper: #f3eee3; --ink: #16110b; --red: #d02a1e; --red-deep: #8f1410; }
  body { background: var(--ink); color: var(--paper); padding: 1.5rem; max-width: 46rem; margin: 0 auto; }
  main { line-height: 1.55; }
  .doc h2 { font-weight: 800; font-size: 1.15rem; text-transform: uppercase; letter-spacing: 0.04em; margin: 1.4rem 0 0.4rem; }
  .doc h3 { font-weight: 700; margin: 1.1rem 0 0.3rem; }
  .doc h2:first-child { margin-top: 0; }
  .doc p { margin: 0.45rem 0; }
  .doc ul { list-style: disc; padding-left: 1.25rem; margin: 0.4rem 0; }
  .doc ol { list-style: decimal; padding-left: 1.25rem; margin: 0.4rem 0; }
  .doc a { color: var(--red); text-decoration: underline; }
  .doc code { font-size: 0.875em; background: rgba(21, 17, 11, 0.14); padding: 0.1rem 0.35rem; border-radius: 3px; }
  .doc pre { margin: 0.6rem 0; }
  .doc pre code { display: block; background: rgb(231, 224, 208); color: rgb(22, 17, 11); padding: 0.65rem 0.85rem; border-radius: 4px; overflow-x: auto; }
  .doc blockquote { border-left: 3px solid var(--red); padding-left: 0.85rem; opacity: 0.86; margin: 0.5rem 0; }
"#;

pub enum DocError {
    NotFound { slug: String },
}

impl std::fmt::Display for DocError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let DocError::NotFound { slug } = self;
        write!(f, "No doc '{slug}'")
    }
}

impl std::fmt::Debug for DocError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}

/// (slug, title, one-line description, markdown). The order is the
/// index order.
pub const DOC_PAGES: &[(&str, &str, &str, &str)] = &[
    (
        "install-script",
        "The install script (macOS / Linux)",
        "One command sets up the demo container tier.",
        include_str!("../content/docs/install-script.md"),
    ),
    (
        "nixos",
        "NixOS install",
        "The native path — a Fortress machine is a NixOS machine.",
        include_str!("../content/docs/nixos.md"),
    ),
    (
        "getting-started",
        "Get started",
        "Claiming a machine, using the services, the dashboard.",
        include_str!("../content/docs/getting-started.md"),
    ),
    (
        "privacy-tips",
        "Privacy tips",
        "Harden your accounts, network and habits.",
        include_str!("../content/docs/privacy-tips.md"),
    ),
];

pub fn page_exists(slug: &str) -> Result<(), DocError> {
    assert_valid_slug(slug)?;
    if DOC_PAGES.iter().any(|(s, ..)| *s == slug) {
        Ok(())
    } else {
        Err(DocError::NotFound { slug: slug.to_string() })
    }
}

fn assert_valid_slug(slug: &str) -> Result<(), DocError> {
    if slug.is_empty() {
        panic!("slug must be non-empty");
    }
    if slug.starts_with('/') || slug.contains("..") {
        return Err(DocError::NotFound { slug: slug.to_string() });
    }
    Ok(())
}

/// Markdown -> HTML, with the site's `doc-code` class on fenced
/// blocks so the whole document stays inline (no third-party origins
/// at runtime).
pub fn doc_html(slug: &str) -> Result<String, DocError> {
    page_exists(slug)?;
    let page = DOC_PAGES
        .iter()
        .find(|(s, ..)| *s == slug)
        .expect("page_exists gates slugs to DOC_PAGES entries");
    let md: &str = page.3;
    let parser = ::pulldown_cmark::Parser::new_ext(md, ::pulldown_cmark::Options::ENABLE_TASKLISTS);
    let mut out = String::with_capacity(md.len());
    ::pulldown_cmark::html::push_html(&mut out, parser);
    Ok(doc_code_restyle(&out))
}

fn doc_code_restyle(rendered: &str) -> String {
    rendered.replace("<pre><code>", "<pre><code class=\"doc-code\">")
}

// ── axum surface (server tier only) ───────────────────────────────

#[cfg(feature = "server")]
pub use server::fullstack_router;

#[cfg(feature = "server")]
pub mod server {
    use super::*;
    use axum::extract::{Path, Request};
    use axum::http::header;
    use axum::http::HeaderMap as AxumHeaderMap;
    use axum::http::StatusCode;
    use axum::middleware::{self, Next};
    use axum::response::{Html, IntoResponse, Response};
    use axum::routing::get;
    use axum::Router;
    use dioxus::prelude::dioxus_fullstack::FullstackContext;
    use dioxus::prelude::dioxus_server::FullstackState;
    use dioxus::prelude::dioxus_server::{
        DioxusRouterExt, ServeConfig, ServerFnError,
    };

    /// The embedded account plane + mailer, injected into every request
    /// as an axum extension so both SSR rendering and the `#[server]`
    /// account functions can reach it. `&'static` like the controlplane
    /// singleton it wraps — built once at boot, lives for the process.
    pub struct SiteBackend {
        pub cp: &'static fortress_controlplane::ControlPlane,
        pub mailer: &'static dyn fortress_controlplane::controlplane::mail::Mailer,
    }

    /// The backend for the current request, or `None` when the router
    /// was built without one (SSR-only tests, or a mis-wired boot).
    fn current_backend() -> Option<&'static SiteBackend> {
        FullstackContext::current().and_then(|ctx| ctx.extension::<&'static SiteBackend>())
    }

    /// The backend or a server-fn error — for the `#[server]` account
    /// functions (which can't return an axum `Response` directly).
    pub fn backend() -> Result<&'static SiteBackend, ServerFnError> {
        current_backend().ok_or_else(|| ServerFnError::new("site backend not wired into request"))
    }

    /// Read the session cookie out of the request headers (works for
    /// both the poem and axum surfaces — shared contract).
    pub fn read_session_cookie(headers: &AxumHeaderMap) -> Option<String> {
        fortress_controlplane::read_cookie_from_headers(headers, fortress_controlplane::SESSION_COOKIE)
    }

    /// Set the session cookie on the current response.
    pub fn set_session_cookie(token: &str) -> Result<(), ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context for session cookie"))?;
        ctx.add_response_header(
            header::SET_COOKIE,
            fortress_controlplane::session_cookie_header(token),
        );
        Ok(())
    }

    /// Clear the session cookie on the current response.
    pub fn clear_session_cookie() -> Result<(), ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context for session cookie"))?;
        ctx.add_response_header(
            header::SET_COOKIE,
            fortress_controlplane::clear_session_cookie_header(),
        );
        Ok(())
    }

    async fn install_sh_route() -> Response {
        (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/x-shellscript; charset=utf-8")],
            include_str!("../../../scripts/install.sh"),
        )
            .into_response()
    }

    async fn docs_index_route() -> Response {
        let items: Vec<String> = DOC_PAGES
            .iter()
            .map(|(slug, title, _, _)| {
                let title: &str = title;
                format!("<li><a href=\"/docs/{slug}\">{title}</a></li>")
            })
            .collect();
        let index = format!("<ul>{}</ul>", items.join(""));
        Html(format!(
            "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Fortress — Docs</title><style>{}</style></head><body><main><h1>Docs</h1></main>{index}</body></html>",
            DOC_CSS,
            index = index
        ))
        .into_response()
    }

    async fn docs_page_route(Path(slug): Path<String>) -> Response {
        if page_exists(&slug).is_err() {
            return (StatusCode::NOT_FOUND, "no such doc").into_response();
        }
        let body = doc_html(&slug).expect("page_exists gated the slug");
        let doc = format!(
            "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Fortress — Docs</title><style>{}</style></head><body><article class=\"doc\">{body}</article></body></html>",
            DOC_CSS
        );
        Html(doc).into_response()
    }

    /// The site router: hard routes first (they win), then the dioxus
    /// SSR application as fallback for everything else (the `/`
    /// landing, the app pages). SSR is wired with the
    /// `serve_api_application` chain — no dx-generated asset dir to
    /// serve, so the static-assets step (which panics without a
    /// `public/` dir) is deliberately skipped.
    ///
    /// `backend` is injected into every request's axum extensions; the
    /// account server functions (`#[server]`) and the SSR components
    /// both read it from `FullstackContext`. `None` (SSR-only tests)
    /// renders the landing + docs but the account routes 500.
    pub fn fullstack_router(backend: Option<&'static SiteBackend>) -> Router {
        let inject_backend = middleware::from_fn(move |mut request: Request, next: Next| {
            if let Some(backend) = backend {
                request.extensions_mut().insert(backend);
            }
            next.run(request)
        });
        Router::new()
            .route("/install.sh", get(install_sh_route))
            .route("/docs", get(docs_index_route))
            .route("/docs/{page}", get(docs_page_route))
            .with_state(FullstackState::headless())
            .register_server_functions()
            .fallback(get(FullstackState::render_handler))
            .with_state(FullstackState::new(ServeConfig::new(), App))
            .layer(inject_backend)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use tower::ServiceExt;

        fn ssr_router() -> Router {
            fullstack_router(None)
        }

        #[tokio::test]
        async fn install_sh_serves_the_repo_script() {
            let response = ssr_router()
                .oneshot(
                    axum::http::Request::builder()
                        .uri("/install.sh")
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert!(response.status().is_success());
            assert_eq!(
                response.headers().get(header::CONTENT_TYPE).unwrap(),
                "text/x-shellscript; charset=utf-8"
            );
        }

        #[tokio::test]
        async fn landing_ssr_renders_the_curl_card() {
            let response = ssr_router()
                .oneshot(
                    axum::http::Request::builder()
                        .uri("/")
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let body: Vec<u8> = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec();
            let body = String::from_utf8(body).unwrap();
            assert!(
                body.contains("curl https://proletariat.tech/install.sh | bash"),
                "the landing renders the curl card: {body}"
            );
        }

        #[tokio::test]
        async fn docs_index_lists_every_page() {
            let response = ssr_router()
                .oneshot(
                    axum::http::Request::builder()
                        .uri("/docs")
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let body: Vec<u8> = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec();
            let body = String::from_utf8(body).unwrap();
            for (slug, ..) in DOC_PAGES {
                assert!(body.contains(slug), "docs index lists '{slug}'");
            }
        }

        #[tokio::test]
        async fn docs_page_renders_markdown() {
            let response = ssr_router()
                .oneshot(
                    axum::http::Request::builder()
                        .uri("/docs/nixos")
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let body: Vec<u8> = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec();
            let body = String::from_utf8(body).unwrap();
            assert!(
                body.contains("<h2"),
                "the nixos doc renders headings: {body}"
            );
        }

        // ── store-backed round trip (needs a real Redis) ────────────

        /// A control plane + mailer for the round-trip test, built
        /// against the REDIS_URL the same way the controlplane's own
        /// store-backed tests are. `None` when REDIS_URL is unset. The
        /// `MockMailer` is returned separately so the test can read
        /// captured mail (the backend only holds the `&dyn Mailer`).
        fn test_backend() -> Option<(&'static SiteBackend, &'static fortress_controlplane::controlplane::mail::MockMailer)> {
            let url = match std::env::var("REDIS_URL") {
                Ok(url) if !url.is_empty() => url,
                _ => return None,
            };
            let wg: &'static fortress_controlplane::MockWgClient =
                Box::leak(Box::new(fortress_controlplane::MockWgClient::new()));
            let dns: &'static fortress_controlplane::MockDnsApiClient =
                Box::leak(Box::new(fortress_controlplane::MockDnsApiClient::new()));
            let subnet = fortress_controlplane::Subnet64::from_str("2a01:4f8:c17:1::/64")
                .expect("test subnet parses");
            let wg_subnet = fortress_controlplane::WgSubnet::from_str("10.10.0.0/24")
                .expect("test wg subnet parses");
            let cp = fortress_controlplane::ControlPlane::with_deps(
                &url,
                subnet,
                wg_subnet,
                "example.net",
                "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=",
                wg,
                dns,
            )
            .expect("test control plane connects");
            let mailer: &'static fortress_controlplane::controlplane::mail::MockMailer =
                Box::leak(Box::new(fortress_controlplane::controlplane::mail::MockMailer::new()));
            let backend: &'static SiteBackend = Box::leak(Box::new(SiteBackend {
                cp: Box::leak(Box::new(cp)),
                mailer,
            }));
            Some((backend, mailer))
        }

        fn unique_email(label: &str) -> String {
            use std::time::{SystemTime, UNIX_EPOCH};
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            format!("{label}-{}-{}@example.com", std::process::id(), nanos)
        }

        fn extract_token(body: &str) -> String {
            let start = body.find("token=").expect("link present") + "token=".len();
            body[start..].lines().next().unwrap().trim().to_string()
        }

        async fn json_post(router: &Router, uri: &str, body: &str) -> Response {
            router
                .clone()
                .oneshot(
                    axum::http::Request::builder()
                        .method("POST")
                        .uri(uri)
                        .header(header::CONTENT_TYPE, "application/json")
                        .body(axum::body::Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap()
        }

        /// The T2a acceptance test: signup → verify → login (session
        /// cookie set) → landing shows the signed-in user → logout
        /// clears it — all against the *new* fullstack surface, not
        /// the poem form handlers.
        #[tokio::test]
        async fn signup_verify_login_logout_fullstack_round_trip() {
            let Some((backend, mailer)) = test_backend() else {
                eprintln!("skipping: REDIS_URL not set");
                return;
            };
            let router = fullstack_router(Some(backend));
            let email = unique_email("fullstack");

            // Signup (server function).
            let resp = json_post(
                &router,
                "/api/auth/signup",
                &format!(r#"{{"email":"{email}","password":"hunter2"}}"#),
            )
            .await;
            assert_eq!(resp.status(), StatusCode::OK);
            let sent = mailer.sent();
            assert_eq!(sent.len(), 1, "signup emails one verification link");
            assert_eq!(sent[0].to, email);
            let token = extract_token(&sent[0].body);

            // Verify (server function) — the account becomes active.
            let resp = json_post(
                &router,
                "/api/auth/verify",
                &format!(r#"{{"token":"{token}"}}"#),
            )
            .await;
            assert_eq!(resp.status(), StatusCode::OK);

            // Login (server function) — response carries the session cookie.
            let resp = json_post(
                &router,
                "/api/auth/login",
                &format!(r#"{{"email":"{email}","password":"hunter2"}}"#),
            )
            .await;
            assert_eq!(resp.status(), StatusCode::OK);
            let set_cookie = resp
                .headers()
                .get(header::SET_COOKIE)
                .expect("login sets the session cookie")
                .to_str()
                .unwrap()
                .to_string();
            assert!(set_cookie.contains("fortress_account_session="));
            assert!(set_cookie.contains("HttpOnly"));
            let session = set_cookie
                .split("fortress_account_session=")
                .nth(1)
                .and_then(|rest| rest.split(';').next())
                .expect("cookie value");

            // The cookie makes the SSR landing show the signed-in user.
            let resp = router
                .clone()
                .oneshot(
                    axum::http::Request::builder()
                        .uri("/")
                        .header(header::COOKIE, format!("fortress_account_session={session}"))
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            let body: Vec<u8> = axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec();
            let body = String::from_utf8(body).unwrap();
            assert!(body.contains("Sign out"), "signed-in nav: {body}");
            assert!(body.contains(&email), "nav shows the account email");

            // Logout (server function) — the cookie is cleared.
            let resp = router
                .clone()
                .oneshot(
                    axum::http::Request::builder()
                        .method("POST")
                        .uri("/api/auth/logout")
                        .header(header::COOKIE, format!("fortress_account_session={session}"))
                        .header(header::CONTENT_TYPE, "application/json")
                        .body(axum::body::Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            assert!(resp
                .headers()
                .get(header::SET_COOKIE)
                .unwrap()
                .to_str()
                .unwrap()
                .contains("Max-Age=0"));

            // The cleared cookie means the landing is logged out again.
            let resp = router.clone().oneshot(
                axum::http::Request::builder()
                    .uri("/")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
            let body: Vec<u8> = axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec();
            let body = String::from_utf8(body).unwrap();
            assert!(body.contains("Create account"), "logged-out nav: {body}");
        }
    }
}

#[cfg(all(test, feature = "server"))]
mod doc_tests {
    use super::*;

    /// The committed index.html must be the zine shell regenerated
    /// from web-ui with the wasm client script in the post-main slot
    /// (dioxus's SSR streams post-#main content as the bundle loader).
    #[test]
    fn public_index_carries_the_zine_shell() {
        let committed = include_str!("../public/index.html");
        let expected = fortress_web_ui::index_shell_html(
            "Fortress — your home server, your rules",
        )
        .replace(
            "<div id=\"main\"></div></body>",
            "<div id=\"main\"></div><script type=\"module\" async src=\"/./wasm/fortress-site.js\"></script></body>",
        );
        assert_eq!(
            committed,
            expected,
            "public/index.html is stale against the zine shell — regenerate with: cargo run -p fortress-web-ui --example write_index > crates/site/public/index.html (then re-insert the wasm script line before </body>)"
        );
    }

    #[test]
    fn doc_pages_have_valid_unique_relative_fragments() {
        for (slug, ..) in DOC_PAGES {
            page_exists(slug).unwrap_or_else(|err| panic!("doc '{slug}' must exist: {err}"));
        }
        for (i, (a, ..)) in DOC_PAGES.iter().enumerate() {
            for (b, ..) in DOC_PAGES.iter().skip(i + 1) {
                assert_ne!(a, b, "doc slugs must be unique");
            }
        }
    }

    #[test]
    fn doc_html_renders_with_restyled_code() {
        for (slug, _, _, _) in DOC_PAGES {
            let rendered = doc_html(slug).unwrap_or_else(|err| panic!("doc '{slug}' must render: {err}"));
            assert!(
                !rendered.contains("<pre><code>"),
                "fenced code restyled (no raw <pre><code> at runtime)"
            );
        }
    }

    #[test]
    fn unknown_slug_is_not_found_loudly() {
        assert!(doc_html("no-such-page").is_err());
    }
}
