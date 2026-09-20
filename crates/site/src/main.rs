#[cfg(feature = "server")]
mod server_main {
    use fortress_controlplane::controlplane::mail::Mailer;
    use fortress_controlplane::{
        ControlPlane, MockDnsApiClient, MockWgClient, Subnet64, WgSubnet,
    };
    use fortress_site::fullstack_router;
    use fortress_site::server::SiteBackend;

    /// Build the site's embedded account backend: a `ControlPlane`
    /// against the store URL plus a mailer, leaked to `'static` for the
    /// router. The WG + DNS clients are mocks — the site never
    /// allocates machines or touches wg0 (that is the edge's job); the
    /// account methods (`signup`/`login`/`session`) are pure Redis +
    /// mailer.
    ///
    /// `dummy` selects the dev boot path: no boot secrets, console
    /// mailer, `dev.local` domain. Otherwise the real secrets are read
    /// (`--dummy` compiles only into debug builds, mirroring the edge).
    fn build_backend(redis_url: &str, subnet: Subnet64, wg_subnet: WgSubnet, dummy: bool) -> &'static SiteBackend {
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let cp = if dummy {
            ControlPlane::with_deps(
                redis_url,
                subnet,
                wg_subnet,
                fortress_controlplane::DUMMY_ROOT_DOMAIN,
                fortress_controlplane::DUMMY_EDGE_WG_PRIV,
                wg,
                dns,
            )
        } else {
            let root_domain = fortress_controlplane::controlplane::secret::root_domain();
            let wg_key = fortress_controlplane::controlplane::secret::wg_private_key();
            ControlPlane::with_deps(redis_url, subnet, wg_subnet, root_domain, wg_key, wg, dns)
        }
        .expect("site control plane connects");
        let mailer: &'static dyn Mailer = if dummy {
            Box::leak(Box::new(fortress_controlplane::controlplane::mail::ConsoleMailer))
        } else {
            Box::leak(
                fortress_controlplane::controlplane::mail::mailer_from_secrets()
                    .expect("mailer init: configured SMTP relay must build"),
            )
        };
        Box::leak(Box::new(SiteBackend {
            cp: Box::leak(Box::new(cp)),
            mailer,
        }))
    }

    #[tokio::main]
    pub async fn run() {
        let args: Vec<String> = std::env::args().skip(1).collect();
        let mut redis_url = "redis://127.0.0.1:6379".to_string();
        let mut subnet = "2a01:4f8:c17:1::/64".to_string();
        let mut wg_subnet = "10.10.0.0/24".to_string();
        let mut dummy = false;
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--redis-url" => {
                    i += 1;
                    redis_url = args[i].clone();
                }
                "--subnet" => {
                    i += 1;
                    subnet = args[i].clone();
                }
                "--wg-subnet" => {
                    i += 1;
                    wg_subnet = args[i].clone();
                }
                #[cfg(debug_assertions)]
                "--dummy" => dummy = true,
                other => {
                    eprintln!("unknown flag {other}");
                    std::process::exit(1);
                }
            }
            i += 1;
        }

        let subnet = Subnet64::from_str(&subnet).unwrap_or_else(|err| {
            eprintln!("bad --subnet: {err}");
            std::process::exit(1);
        });
        let wg_subnet = WgSubnet::from_str(&wg_subnet).unwrap_or_else(|err| {
            eprintln!("bad --wg-subnet: {err}");
            std::process::exit(1);
        });

        let backend = build_backend(&redis_url, subnet, wg_subnet, dummy);

        // 0.0.0.0 — the site is a public surface (the edge on :8081
        // binds the same way); 127.0.0.1 would strand it on the dev box.
        let listener = tokio::net::TcpListener::bind("0.0.0.0:8082")
            .await
            .expect("fortress-site: reserve 0.0.0.0:8082");
        println!("fortress-site serving on 0.0.0.0:8082");
        axum::serve(listener, fullstack_router(Some(backend)))
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