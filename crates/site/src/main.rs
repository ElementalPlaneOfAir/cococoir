use fortress_site::fullstack_router;

#[tokio::main]
async fn main() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8082")
        .await
        .expect("fortress-site: reserve 127.0.0.1:8082");
    println!("fortress-site serving on 127.0.0.1:8082");
    axum::serve(listener, fullstack_router())
        .await
        .expect("fortress-site: serve");
}
