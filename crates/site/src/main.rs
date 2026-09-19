#[cfg(feature = "server")]
mod server_main {
    use fortress_site::fullstack_router;

    #[tokio::main]
    pub async fn run() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:8082")
            .await
            .expect("fortress-site: reserve 127.0.0.1:8082");
        println!("fortress-site serving on 127.0.0.1:8082");
        axum::serve(listener, fullstack_router())
            .await
            .expect("fortress-site: serve");
    }
}

#[cfg(all(feature = "web", not(feature = "server")))]
mod web_main {
    pub fn run() {
        dioxus::launch(fortress_site::App);
    }
}

#[cfg(all(feature = "server", not(feature = "web")))]
fn main() {
    server_main::run();
}

#[cfg(all(feature = "web", not(feature = "server")))]
fn main() {
    web_main::run();
}

#[cfg(all(feature = "server", feature = "web"))]
compile_error!("fortress-site: server and web tiers are mutually exclusive — build the server with --no-default-features --features server, the wasm client with --no-default-features --features web");
