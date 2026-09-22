//! `GET /install.sh` — the repo's installer, served inline. It is a
//! shell script, not HTML, so it is a `#[route]` (registered with
//! `.route()`, not `.page()`).

use topcoat::{
    Result as TcResult,
    router::{content::Html, route},
};

#[route(GET "/install.sh")]
pub async fn install_sh() -> TcResult<Html<&'static str>> {
    Ok(Html(include_str!("../../../../scripts/install.sh")))
}
