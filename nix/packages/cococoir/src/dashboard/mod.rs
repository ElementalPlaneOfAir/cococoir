mod components;
mod nix_config_parser;
use poem::{
    get, handler, listener::TcpListener, web::Html, web::Path, IntoResponse, Route, Server,
};
use std::sync::atomic::{AtomicUsize, Ordering};

use askama::Template; // bring trait in scope

#[derive(Template)] // this will generate the code...
#[template(path = "hello.html")] // using the template in this path, relative
struct HelloTemplate<'a> {
    // the name of the struct can be anything
    name: &'a str, // the field name should match the variable name
    // in your template
    times_loaded: usize,
}

static COUNTER: AtomicUsize = AtomicUsize::new(1);
#[handler]
fn hello(Path(name): Path<String>) -> Html<String> {
    let times_loaded = COUNTER.fetch_add(1, Ordering::Relaxed);
    let template = HelloTemplate {
        name: &name,
        times_loaded,
    };
    Html(template.render().unwrap())
}
pub async fn dashboard_entry() -> Result<(), std::io::Error> {
    let app = Route::new().at("/hello/:name", get(hello));
    Server::new(TcpListener::bind("0.0.0.0:3000"))
        .run(app)
        .await
}
