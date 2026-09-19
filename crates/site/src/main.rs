//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! The site binary: plain axum serving the static surfaces while the
//! dioxus fullstack scaffold for the stateful pages lands next
//! session (it needs the `wasm32-unknown-unknown` client target —
//! not yet installed on this toolchain). The poem controlplane
//! continues to host the app pages (register/login/machines) until
//! that cut.
use fortress_site::site_routes;

#[tokio::main]
async fn main() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8082")
        .await
        .expect("fortress-site: reserve 127.0.0.1:8082");
    println!("fortress-site serving on 127.0.0.1:8082");
    let app = site_routes();
    axum::serve(listener, app)
        .await
        .expect("fortress-site: serve");
}

