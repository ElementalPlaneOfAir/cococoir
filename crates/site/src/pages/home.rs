//! The landing page. The marketing copy is static zine markup owned by
//! `fortress-web-ui` (`landing_html`), shared byte-for-byte with the
//! edge's control-plane landing — so it is injected raw rather than
//! re-expressed in `view!`. Only the nav's signed-in state is live.

use topcoat::{
    Result as TcResult,
    context::Cx,
    view::{Unescaped, View, view},
};

use crate::account::{self, SessionState};
use crate::site_backend;
use fortress_web_ui::LandingProps;

/// The signed-in nav/CTA is the only dynamic part of the landing; it
/// rides on the same `landing_html` shell the edge serves.
#[topcoat::router::page("/")]
pub async fn home(cx: &Cx) -> TcResult<impl View> {
    let backend = site_backend(cx);
    let headers = topcoat::router::request::headers(cx).clone();
    let session = account::current_session(backend, &headers).await;

    let props = match &session {
        SessionState::LoggedIn { email } => LandingProps {
            logged_in: true,
            email: Some(email.clone()),
        },
        SessionState::Anonymous => LandingProps {
            logged_in: false,
            email: None,
        },
    };

    let landing = fortress_web_ui::landing_html(&props);
    Ok(view! {
        <main>
            (Unescaped::new_unchecked(landing))
        </main>
    })
}
