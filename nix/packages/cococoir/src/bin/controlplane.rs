use cococoir::controlplane::controlplane_entry;

/// cococoir-controlplane: the remote-access provisioning service
/// (ADR-025). Allocates /128s from the edge's routed subnet, generates
/// WG keypairs at signup, stores customers in Redis.
///
/// The subnet prefix is NOT assumed to be /64 — an operator managing
/// one shared /64 may hand the box a /72 or /96 slice of it. Any
/// byte-aligned /64..=/112 works.
///
/// Usage:
///   cococoir-controlplane --redis-url redis://127.0.0.1:6379 \
///     --subnet 2a01:4f8:c17:1::/64
#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    let mut redis_url = "redis://127.0.0.1:6379".to_string();
    let mut subnet = String::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args.next().ok_or_else(|| {
            std::io::Error::other(format!("{arg} requires a value"))
        })?;
        match arg.as_str() {
            "--redis-url" => redis_url = value,
            "--subnet" => subnet = value,
            other => {
                eprintln!("unknown flag {other}");
                return Err(std::io::Error::other("usage: cococoir-controlplane --redis-url URL --subnet /64..=/112"));
            }
        }
    }
    if subnet.is_empty() {
        return Err(std::io::Error::other(
            "missing --subnet (the edge box's routed subnet, e.g. 2a01:4f8:c17:1::/64)",
        ));
    }
    controlplane_entry(redis_url, subnet).await
}
