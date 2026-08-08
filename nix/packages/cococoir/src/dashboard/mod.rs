pub mod components;
mod nix_config_parser;
use poem::{
    get, handler,
    http::StatusCode,
    listener::TcpListener,
    web::{Html, Path},
    IntoResponse, Route, Server,
};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::dashboard::components::{IndexPage, IndexProps};

static COUNTER: AtomicUsize = AtomicUsize::new(1);
#[handler]
fn hello(Path(name): Path<String>) -> impl IntoResponse {
    let times_loaded = COUNTER.fetch_add(1, Ordering::Relaxed);
    let props = IndexProps {
        count: times_loaded,
    };
    let node = IndexPage(&props);
    Html(node.to_html()).with_status(StatusCode::OK)
}
pub async fn dashboard_entry() -> Result<(), std::io::Error> {
    let app = Route::new().at("/hello/:name", get(hello));
    Server::new(TcpListener::bind("0.0.0.0:3000"))
        .run(app)
        .await
}
