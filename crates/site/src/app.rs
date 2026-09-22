//! The topcoat router: every human HTML surface. [`crate::server::app`]
//! composes it with the axum `/api/*` tree.

use topcoat::router::{Router, tower::TowerService};

use crate::SiteBackend;
use crate::pages::{auth, docs, home, install, shell};

/// The pages router. `backend` is registered as topcoat app context so
/// every handler can reach the account plane with `app_context(cx)`.
pub fn pages_router(backend: &'static SiteBackend) -> Router {
    Router::builder()
        .layout(shell::root_layout)
        .app_context(backend)
        .page(home::home)
        .page(docs::docs_index)
        .page(docs::docs_page)
        .page(auth::register_get)
        .page(auth::register_post)
        .page(auth::login_get)
        .page(auth::login_post)
        .page(auth::logout_post)
        .page(auth::forgot_get)
        .page(auth::forgot_post)
        .page(auth::reset_get)
        .page(auth::reset_post)
        .page(auth::verify_get)
        .page(auth::verify_post)
        .page(auth::resend_get)
        .page(auth::resend_post)
        .page(auth::join)
        .page(auth::account_delete_get)
        .page(auth::account_delete_post)
        // `#[route]`, not `#[page]`: /install.sh is a shell script.
        .route(install::install_sh)
        .build()
}

/// topcoat as a tower service, for mounting as axum's fallback. This is
/// the seam proven by the T1 spike: topcoat sees FULL request paths, so
/// `#[shard]`/`#[procedure]` runtime routes resolve once T4 lands.
pub fn pages_service(backend: &'static SiteBackend) -> TowerService {
    TowerService::new(pages_router(backend))
}
