//! Boot: build the account plane, hand it to the composed router, bind.

use fortress_site::SiteBackend;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut redis_url = "redis://127.0.0.1:6379".to_string();
    let mut subnet = "2a01:4f8:c17:1::/64".to_string();
    let mut wg_subnet = "10.10.0.0/24".to_string();
    let mut root_domain = "proletariat.tech".to_string();
    let mut addr = "127.0.0.1:8082".to_string();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let mut take = |flag: &str| -> Option<String> {
            if args.get(i).map(String::as_str) == Some(flag) {
                i += 1;
                args.get(i).cloned()
            } else {
                None
            }
        };
        if let Some(v) = take("--redis-url") { redis_url = v; i += 1; continue; }
        if let Some(v) = take("--subnet") { subnet = v; i += 1; continue; }
        if let Some(v) = take("--wg-subnet") { wg_subnet = v; i += 1; continue; }
        if let Some(v) = take("--domain") { root_domain = v; i += 1; continue; }
        if let Some(v) = take("--addr") { addr = v; i += 1; continue; }
        eprintln!("unknown or incomplete arg: {}", args[i]);
        i += 1;
    }

    let subnet = fortress_controlplane::Subnet64::from_str(&subnet)
        .map_err(|e| format!("--subnet: {e}"))?;
    let wg_subnet = fortress_controlplane::WgSubnet::from_str(&wg_subnet)
        .map_err(|e| format!("--wg-subnet: {e}"))?;
    // `ControlPlane::with_deps` holds these for the process lifetime;
    // leak them the way the store-backed tests do rather than thread
    // a lifetime through every page handler.
    let redis_url: &'static str = Box::leak(redis_url.into_boxed_str());
    let root_domain: &'static str = Box::leak(root_domain.into_boxed_str());
    // Dev/dummy identity: the same dummy edge WG key the edge's
    // `--dummy` path injects. T6 replaces this with the store-held
    // production key (secret resolution) once the site serves prod.
    let wg: &'static fortress_controlplane::MockWgClient =
        Box::leak(Box::new(fortress_controlplane::MockWgClient::new()));
    let dns: &'static fortress_controlplane::MockDnsApiClient =
        Box::leak(Box::new(fortress_controlplane::MockDnsApiClient::new()));
    let cp = fortress_controlplane::ControlPlane::with_deps(
        redis_url,
        subnet,
        wg_subnet,
        root_domain,
        fortress_controlplane::DUMMY_EDGE_WG_PRIV,
        wg,
        dns,
    )?;

    let backend: &'static SiteBackend = Box::leak(Box::new(SiteBackend {
        cp,
        mailer: Box::new(fortress_controlplane::controlplane::mail::ConsoleMailer),
    }));

    let app = fortress_site::server::app(backend);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    eprintln!("fortress-site listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
