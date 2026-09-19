//! The site crate, one dioxus fullstack surface: plain axum routes for
//! `/install.sh` and the markdown wiki (document-origin-only rendering
//! law), plus dioxus SSR for the stateful pages. The axum tier is
//! disabled when the client (`dx --platform web`) compiles with
//! `--no-default-features --features web`, since axum cannot run on
//! wasm.
use dioxus::prelude::*;

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
}

#[component]
pub fn Home() -> Element {
    rsx! {
        main {
            h1 { "Fortress" }
            p { "Your own private internet: chat, files, pics and videos of the backend." }
            pre { class: "install", "curl https://proletariat.tech/install.sh | bash" }
            a { href: "/docs", "Read the docs" }
        }
        style { {doc_css()} }
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
mod server {
    use super::*;
    use axum::extract::Path;
    use axum::http::header;
    use axum::http::StatusCode;
    use axum::response::{Html, IntoResponse, Response};
    use axum::routing::get;
    use axum::Router;

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
    /// landing, later the app pages). SSR is wired with the
    /// `serve_api_application` chain — no dx-generated asset dir to
    /// serve, so the static-assets step (which panics without a
    /// `public/` dir) is deliberately skipped.
    pub fn fullstack_router() -> Router {
        use dioxus::prelude::dioxus_server::{DioxusRouterExt, FullstackState, ServeConfig};
        Router::new()
            .route("/install.sh", get(install_sh_route))
            .route("/docs", get(docs_index_route))
            .route("/docs/{page}", get(docs_page_route))
            .with_state(FullstackState::headless())
            .register_server_functions()
            .fallback(get(FullstackState::render_handler))
            .with_state(FullstackState::new(ServeConfig::new(), App))
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use tower::ServiceExt;

        #[tokio::test]
        async fn install_sh_serves_the_repo_script() {
            let response = fullstack_router()
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
            let response = fullstack_router()
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
            let response = fullstack_router()
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
            let response = fullstack_router()
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
    }
}

#[cfg(all(test, feature = "server"))]
mod doc_tests {
    use super::*;

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
