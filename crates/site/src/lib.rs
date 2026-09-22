//! The site: one topcoat presentation surface plus an axum `/api/*`
//! machine contract, composed into a single listener.
//!
//! Boundary (the separation of concerns that shapes this crate):
//!   - **axum + utoipa** owns `/api/*` — the client-facing `pairing.rs`
//!     contract, health, and `/api/openapi.json`. Machine-facing, must
//!     survive byte-for-byte, must stay on plain HTTP handlers so utoipa
//!     can derive the wire shape.
//!   - **topcoat** owns every human HTML surface. Server-rendered, no
//!     wasm, no hydration step — the forms POST and redirect (PRG), so a
//!     missing client script degrades to a safe 405/redirect rather than
//!     a credential leak.
//!
//! topcoat is adopted for rendering and routing ONLY. `topcoat-mail`,
//! `topcoat-session`, `topcoat-asset`/`font`/`icon` and `topcoat-ui` are
//! deliberately not used — controlplane's `Mailer` and session store are
//! tested and secrets-wired, and web-ui's ZINE_CSS/LOUD_CSS is the
//! zero-external-origin design system. See `Cargo.toml`.

pub mod account;
pub mod api;
pub mod app;
pub mod pages;
pub mod server;

use fortress_controlplane::ControlPlane;
use fortress_controlplane::controlplane::mail::Mailer;

/// The account plane + mailer, registered as topcoat app context so
/// every handler reaches it with `app_context(cx)`. Built once at boot,
/// lives for the process.
pub struct SiteBackend {
    pub cp: ControlPlane,
    pub mailer: Box<dyn Mailer>,
}

/// The registered app-context type. The router registers `&'static
/// SiteBackend` (the reference), so readers must ask for the reference
/// type — topcoat keys context by `TypeId`, and `SiteBackend` (by
/// value) is a different key than `&'static SiteBackend`. This is the
/// single seam between the pages and the process-lifetime backend.
pub fn site_backend(cx: &topcoat::context::Cx) -> &'static SiteBackend {
    *app_context::<&'static SiteBackend>(cx)
}

use topcoat::context::app_context;

// ── the markdown wiki (document-origin-only rendering law) ──────────

pub fn doc_css() -> &'static str {
    DOC_CSS
}

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

/// Markdown -> HTML, with the site's `doc-code` class on fenced blocks so
/// the whole document stays inline (no third-party origins at runtime).
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

#[cfg(test)]
mod doc_tests {
    use super::{DOC_PAGES, doc_html, page_exists};

    #[test]
    fn doc_pages_have_valid_unique_relative_fragments() {
        for (slug, ..) in DOC_PAGES {
            page_exists(slug)
                .unwrap_or_else(|err| panic!("doc '{slug}' must exist: {err}"));
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
            let rendered = doc_html(slug)
                .unwrap_or_else(|err| panic!("doc '{slug}' must render: {err}"));
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

#[cfg(test)]
mod form_safety_tripwires {
    use crate::pages::auth::{field, form, submit, text_input};

    /// A form carrying a credential field must declare `method="post"`.
    /// HTML defaults a method-less form to GET, so a missing or broken
    /// client submit handler sends the password in the query string —
    /// browser history, server logs, and Referer headers all read it.
    ///
    /// This is the no-JS floor. The dioxus port shipped exactly this bug
    /// (`<form onsubmit=...>` with no method), which is why the site is
    /// now server-rendered with Post/Redirect/Get.
    #[test]
    fn credential_forms_declare_post() {
        // Assert against the builder's real output — this is the exact
        // markup the browser receives, not a guess about the source.
        for action in ["/login", "/register"] {
            let built = form(
                action,
                &[
                    field("Email", &text_input("email", "email")),
                    field("Password", &text_input("password", "password")),
                    submit("Go"),
                ],
            );
            let open = built
                .find("<form")
                .unwrap_or_else(|| panic!("builder must emit a <form> for {action}"));
            let close = built[open..]
                .find('>')
                .unwrap_or_else(|| panic!("<form> must close for {action}"));
            let open_tag = &built[open..open + close + 1];
            assert!(
                open_tag.contains("method=\"post\""),
                "credential form for {action} must declare method=\"post\", got: {open_tag}"
            );
            let body = &built[open + close + 1..];
            assert!(
                body.contains("type=\"password\""),
                "the credential field must sit inside the form: {built}"
            );
        }
    }

    /// A raw `<form` literal anywhere in the page sources must also carry
    /// `method="post"`, so a future hand-rolled form cannot dodge the
    /// builder and reintroduce the GET leak.
    #[test]
    fn no_form_literal_omits_post() {
        let sources: &[&str] = &[
            include_str!("pages/auth.rs"),
            include_str!("pages/home.rs"),
            include_str!("pages/docs.rs"),
            include_str!("pages/install.rs"),
            include_str!("pages/shell.rs"),
        ];
        let mut checked = 0usize;
        for source in sources {
            // Drop comment lines first: a doc comment mentioning `<form>`
            // is not markup and must not trip (or hide) the check.
            let source: String = source
                .lines()
                .filter(|line| !line.trim_start().starts_with("//"))
                .collect::<Vec<_>>()
                .join("\n");
            let source = source.as_str();
            let mut cursor = 0usize;
            while let Some(rel) = source[cursor..].find("<form") {
                let start = cursor + rel;
                let Some(close) = source[start..].find('>') else {
                    break;
                };
                // The builder's `method="post"` lives inside a format!
                // string, so its source text is backslash-escaped. Normalize
                // before matching or the tripwire misses the very form it exists
                // to protect.
                let open_tag = source[start..start + close + 1].replace('\\', "");
                checked += 1;
                assert!(
                    open_tag.contains("method=\"post\""),
                    "a <form> literal at byte {start} must declare method=\"post\" — a no-JS submit would put credentials in the query string"
                );
                cursor = start + close + 1;
            }
        }
        assert!(
            checked >= 1,
            "expected at least the shared form builder's <form> literal, found {checked} — the tripwire no longer matches the source shape"
        );
    }
}

#[cfg(test)]
mod wire_contract_tripwires {
    use crate::api::{BeginBody, MachineInfo, PollOutcome, PubkeyOut, RegisterBody};

    /// `crates/client/src/pairing.rs` reads these exact keys. The mixed
    /// style (snake in, camel out) is the contract; tidying it breaks
    /// enrollment silently. Two assertions: the request shapes stay
    /// snake, and the response shapes keep their deliberate mix.
    #[test]
    fn pairing_wire_shapes_hold() {
        let begin = serde_json::to_value(BeginBody {
            public_key: "pk".into(),
        })
        .expect("BeginBody serializes");
        assert!(
            begin.get("public_key").is_some(),
            "begin request key is snake: {begin}"
        );

        let register = serde_json::to_value(RegisterBody {
            device_token: "tok".into(),
            public_key: "pk".into(),
        })
        .expect("RegisterBody serializes");
        assert!(
            register.get("device_token").is_some(),
            "register request key is snake: {register}"
        );

        let poll = serde_json::to_value(PollOutcome {
            status: "approved".into(),
            machine: Some(MachineInfo { wg_ip: "10.10.0.3".into() }),
            device_token: Some("tok".into()),
        })
        .expect("PollOutcome serializes");
        assert!(
            poll.get("deviceToken").is_some(),
            "poll response deviceToken is camel: {poll}"
        );
        assert!(
            poll.pointer("/machine/wg_ip").is_some(),
            "poll nests machine.wg_ip in snake: {poll}"
        );

        let pk = serde_json::to_value(PubkeyOut {
            public_key: "pk".into(),
        })
        .expect("PubkeyOut serializes");
        assert!(
            pk.get("public_key").is_some(),
            "pubkey response key is snake: {pk}"
        );
    }
}

#[cfg(test)]
mod composition_tripwires {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    /// A test backend: mock WG/DNS clients, a valid dummy edge key, no
    /// live Redis (the store calls fail loudly — which the tripwires
    /// below assert on where it matters).
    fn test_backend() -> &'static SiteBackend {
        let wg: &'static fortress_controlplane::MockWgClient =
            Box::leak(Box::new(fortress_controlplane::MockWgClient::new()));
        let dns: &'static fortress_controlplane::MockDnsApiClient =
            Box::leak(Box::new(fortress_controlplane::MockDnsApiClient::new()));
        let subnet = fortress_controlplane::Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = fortress_controlplane::WgSubnet::from_str("10.10.0.0/24").unwrap();
        let cp = fortress_controlplane::ControlPlane::with_deps(
            "redis://127.0.0.1:6399",
            subnet,
            wg_subnet,
            "example.net",
            fortress_controlplane::DUMMY_EDGE_WG_PRIV,
            wg,
            dns,
        )
        .expect("test control plane builds");
        Box::leak(Box::new(SiteBackend {
            cp,
            mailer: Box::new(fortress_controlplane::controlplane::mail::ConsoleMailer),
        }))
    }

    fn get_req(uri: &str) -> axum::extract::Request {
        axum::http::Request::builder()
            .method("GET")
            .uri(uri)
            .body(Body::empty())
            .unwrap()
    }

    async fn body_string(res: axum::response::Response) -> String {
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// SEAM #1 — axum's `nest("/api", …)` strips the prefix; this crate
    /// must merge at the root instead. The exact `pairing.rs` wire path
    /// landing is the assert, not a synthetic health endpoint.
    ///
    /// Each assert uses a branch of the REAL domain that answers BEFORE
    /// touching the store (no live Redis in L0): code + pubkey validation
    /// are pre-store, so the status codes prove the handler ran — a
    /// missed route would 404 through to topcoat, never return a
    /// domain-shaped 400/200.
    #[tokio::test]
    async fn pairing_wire_paths_land_on_the_api_tree() {
        let app = api::router(test_backend());
        // begin: valid-shaped code, invalid pubkey → domain's
        // InvalidPubkey (400), not a stub. The exact wire path resolves.
        let res = app
            .clone()
            .oneshot(axum::http::Request::builder()
                .method("POST")
                .uri("/api/invites/ABC123XYZ0/begin")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"public_key":"not-a-pubkey"}"#))
                .unwrap())
            .await
            .unwrap();
        assert_eq!(
            res.status(), 400,
            "POST /api/invites/{{code}}/begin must reach the domain's validation"
        );

        // poll: structurally invalid code → domain's InvalidCode (400).
        let res = app
            .clone()
            .oneshot(get_req("/api/invites/short/poll"))
            .await
            .unwrap();
        assert_eq!(
            res.status(), 400,
            "GET /api/invites/{{code}}/poll must reach the domain's validation"
        );

        // pubkey is a pure derivation — no store — so it answers 200
        // with the real edge identity (the dummy key derives a pubkey),
        // proving the stub's empty-string contract is gone.
        let res = app
            .clone()
            .oneshot(get_req("/api/wireguard/pubkey"))
            .await
            .unwrap();
        assert_eq!(res.status(), 200, "pubkey needs no store");
        let body = body_string(res).await;
        assert!(
            body.contains("public_key") && !body.contains("\"public_key\":\"\""),
            "pubkey response carries a real edge identity, not the stub's empty key: {body}"
        );

        // register: invalid pubkey → domain's InvalidPubkey (400) before
        // the store. A stub returned 204 regardless; the real domain
        // rejects the bad key.
        let res = app
            .oneshot(axum::http::Request::builder()
                .method("POST")
                .uri("/api/device/register")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"device_token":"t","public_key":"not-a-pubkey"}"#))
                .unwrap())
            .await
            .unwrap();
        assert_eq!(
            res.status(), 400,
            "POST /api/device/register must reach the domain's validation"
        );
    }

    /// SEAM #2 — OpenAPI survives the merge. It is the reason for the
    /// router-merge (topcoat has no OpenAPI on its roadmap at all).
    #[tokio::test]
    async fn openapi_spec_carries_the_pairing_contract() {
        let app = api::router(test_backend());
        let res = app.oneshot(get_req("/api/openapi.json")).await.unwrap();
        assert_eq!(res.status(), 200, "/api/openapi.json must be reachable");
        let body = body_string(res).await;
        assert!(
            body.contains("/api/invites/{code}/begin"),
            "spec documents the pairing contract: {body}"
        );
    }

    /// SEAM #4 — the app-context registration seam. The router registers
    /// `&'static SiteBackend` (a reference) and pages read it back; the
    /// read must ask for the REFERENCE type, because topcoat keys context
    /// by `TypeId` and `SiteBackend` (by value) is a different key. A
    /// page that reaches for the backend panics at request time if this
    /// drifts — this renders the landing through the COMPOSED router and
    /// asserts it answers, so the drift fails here, not on a live boot.
    #[tokio::test]
    async fn composed_router_renders_a_page_that_reads_app_context() {
        let app = server::app(test_backend());
        let res = app.oneshot(get_req("/")).await.unwrap();
        assert_eq!(
            res.status(), 200,
            "GET / must render (proves the page reaches the backend via app_context)"
        );
        let body = body_string(res).await;
        assert!(
            body.contains("Fortress"),
            "landing renders the zine shell: {body}"
        );
    }

    /// SEAM #3 — no third-party origins at runtime. The CDN creeping
    /// back into one page is exactly the failure this catches.
    #[test]
    fn pages_have_no_external_asset_origins() {
        let pages: &[(&str, String)] = &[
            ("landing", fortress_web_ui::landing_html(&fortress_web_ui::LandingProps {
                logged_in: false,
                email: None,
            })),
            ("landing-logged-in", fortress_web_ui::landing_html(&fortress_web_ui::LandingProps {
                logged_in: true,
                email: Some("x@y".into()),
            })),
            ("shell-css", format!(
                "{}{}",
                fortress_web_ui::ZINE_CSS,
                fortress_web_ui::LOUD_CSS
            )),
        ];
        let banned = [
            "<script src=\"http",
            "<img src=\"http",
            "<iframe src=\"http",
            "<link href=\"http",
            "url(http",
            "cdn.jsdelivr",
            "cdnjs.cloudflare",
            "fonts.googleapis",
        ];
        for (name, html) in pages {
            for needle in banned {
                assert!(
                    !html.contains(needle),
                    "page '{name}' references a third-party origin ({needle}); assets must be inlined"
                );
            }
        }
    }
}
