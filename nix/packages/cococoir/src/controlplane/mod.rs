// SPDX-License-Identifier: AGPL-3.0-or-later
//! Control plane — the remote-access provisioning service.
//!
//! ADR-025: this is a *separate minimal service* from the client
//! dashboard. The dashboard manages household users on one server
//! (sqlite); this service manages *customers* on the edge (Redis).
//!
//! What it does today (demo slice):
//!   - `POST /signup` — allocate the next `/128` from the box's
//!     routed subnet, generate a WireGuard keypair, store the
//!     customer in Redis, return the private key + IP once. The
//!     customer's box dials out to the edge with that key; nothing on
//!     the running edge changes (its forwards already bind the whole
//!     customer prefix range).
//!   - `GET /customers` — list.
//!   - `DELETE /customers/:id` — remove (disruption-free: the edge
//!     drops the WG peer via `wg set`, no restart).
//!
//! Storage is Redis. The state (customers, allocations, keys) is
//! recoverable — a lost allocation is rebuilt from DNS AAAA records +
//! the edge's WG peers — so Redis's simplicity wins over a SQL store.
//! Durability is AOF + `appendfsync always` (configured in the NixOS
//! module), deliberately not assumed.
//!
//! The `/128` allocation uses an atomic Redis counter (`INCR` on a
//! Lua-free single key — INCR is atomic in Redis). Host 1 is the
//! edge's own primary `/128`; customers start at host 2.

pub mod routing_config;
pub use routing_config::{RoutingTable, WgPeer};

use std::net::Ipv6Addr;
use std::sync::Arc;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use poem::{
    handler,
    http::StatusCode,
    post,
    web::{Data, Json, Path},
    Endpoint, EndpointExt, IntoResponse, Response, Route,
};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};

/// Redis key namespace for the control plane.
const CUST_KEY: &str = "cococoir:customer:";
/// Redis key holding the next free host index within the box subnet.
const ALLOC_COUNTER: &str = "cococoir:alloc:next";
/// Redis key holding the list of customer ids.
const CUST_INDEX: &str = "cococoir:customers";

/// The edge's routed IPv6 subnet, e.g. `2a01:4f8:c17:1::/64`.
///
/// The prefix length is NOT assumed to be `/64`: an operator who
/// manages one shared `/64` may hand each edge box a `/72` or `/96`
/// slice of it. `prefix` holds only the network bits (the host bits
/// are always zero); `host(index)` places the host index into the
/// trailing `128 - prefix_len` bits.
#[derive(Debug, Clone)]
pub struct Subnet64 {
    /// The `prefix_len` network bits as bytes (everything up to the
    /// prefix boundary).
    prefix: Vec<u8>,
    /// Prefix length in bits.
    prefix_len: u8,
}

impl Subnet64 {
    pub fn from_str(s: &str) -> Result<Self, String> {
        let (addr_str, len_str) = s
            .rsplit_once('/')
            .ok_or_else(|| format!("invalid subnet {s}: missing /len"))?;
        let prefix_len: u8 = len_str
            .parse()
            .map_err(|_| format!("invalid prefix length in {s}"))?;
        // Prefixes of interest are /64 and finer (a /64, or a /72//96
        // slice of a shared /64). Accept any byte-aligned /64..=/112:
        // finer than that and you cannot fit a host index safely.
        if prefix_len < 64 || prefix_len > 112 || prefix_len % 8 != 0 {
            return Err(format!(
                "{s}: prefix length must be byte-aligned and between /64 and /112 (was /{prefix_len})"
            ));
        }
        let addr: Ipv6Addr = addr_str
            .parse()
            .map_err(|err| format!("invalid subnet {addr_str}: {err}"))?;
        let octets = addr.octets();
        let prefix_bytes = (prefix_len / 8) as usize;
        // The host bits (everything from the prefix boundary on) must
        // be zero in the subnet string.
        if octets[prefix_bytes..].iter().any(|&b| b != 0) {
            return Err(format!("{s} is not a /{prefix_len} (host bits set)"));
        }
        Ok(Self {
            prefix: octets[..prefix_bytes].to_vec(),
            prefix_len,
        })
    }

    /// The `/128` for a host index (host 1 = the edge's primary
    /// address, host 2+ = customers). Index fills the trailing
    /// `128 - prefix_len` bits.
    fn host(&self, index: u64) -> Ipv6Addr {
        let host_bits = 128 - self.prefix_len as u64;
        let max_host = if host_bits >= 64 {
            u64::MAX
        } else {
            (1u64 << host_bits) - 1
        };
        if index > max_host {
            panic!("host index {index} exceeds /{} capacity", self.prefix_len);
        }
        let mut octets = [0u8; 16];
        octets[..self.prefix.len()].copy_from_slice(&self.prefix);
        let idx_bytes = index.to_be_bytes();
        let prefix_bytes = self.prefix.len();
        let host_bytes = (host_bits as usize) / 8;
        let src_start = 8 - host_bytes;
        octets[prefix_bytes..].copy_from_slice(&idx_bytes[src_start..]);
        Ipv6Addr::from(octets)
    }

    /// Human-readable `/128` for `index`.
    pub fn host_string(&self, index: u64) -> String {
        self.host(index).to_string()
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Customer {
    pub id: String,
    pub ipv6: String,
    pub wg_public_key: String,
}

/// The signup response. The private key is returned ONCE — after this
/// it is gone from the service (only the public key is stored).
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SignupResponse {
    pub customer: Customer,
    pub wg_private_key: String,
}

/// Error surface for control-plane operations.
#[derive(Debug, thiserror::Error)]
pub enum ControlPlaneError {
    #[error("redis error: {0}")]
    Redis(#[from] redis::RedisError),
    #[error("customer not found: {0}")]
    NotFound(String),
    #[error("allocation exhausted: {0}")]
    AllocExhausted(String),
}

/// The control plane. Holds the Redis connection and the subnet.
#[derive(Clone)]
pub struct ControlPlane {
    client: redis::Client,
    subnet: Arc<Subnet64>,
}

impl ControlPlane {
    /// Connect to Redis and derive the box subnet.
    pub fn new(redis_url: &str, subnet: Subnet64) -> Result<Self, ControlPlaneError> {
        let client = redis::Client::open(redis_url)?;
        Ok(Self {
            client,
            subnet: Arc::new(subnet),
        })
    }

    async fn conn(&self) -> Result<redis::aio::Connection, ControlPlaneError> {
        Ok(self.client.get_async_connection().await?)
    }

    /// Allocate the next `/128` and create a customer.
    pub async fn signup(&self) -> Result<SignupResponse, ControlPlaneError> {
        let mut conn = self.conn().await?;
        // Host 1 is the edge's own primary /128; customers start at 2.
        // SETNX seeds the counter atomically so the first INCR returns 2.
        let _: () = conn.set_nx(ALLOC_COUNTER, 1).await?;
        // INCR is atomic: no two signups can get the same host index.
        let index: i64 = conn.incr(ALLOC_COUNTER, 1).await?;
        if index < 2 {
            return Err(ControlPlaneError::AllocExhausted(
                "allocation counter below host 2".to_string(),
            ));
        }
        let ipv6 = self.subnet.host_string(index as u64);

        let id = uuid::Uuid::new_v4().to_string();
        let (public_key, private_key) = generate_wg_keypair();
        let customer = Customer {
            id: id.clone(),
            ipv6,
            wg_public_key: public_key,
        };

        let key = format!("{CUST_KEY}{id}");
        let json = serde_json::to_string(&customer).expect("customer serializes");
        // The set is conditional on the id being new; a fresh uuid
        // cannot collide, but assert it anyway (defensive).
        let set: bool = conn.set_nx(&key, json).await?;
        assert!(set, "fresh customer id must not collide");
        let _: i64 = conn.rpush(CUST_INDEX, &id).await?;

        Ok(SignupResponse {
            customer,
            wg_private_key: private_key,
        })
    }

    /// List customers in allocation order.
    pub async fn list(&self) -> Result<Vec<Customer>, ControlPlaneError> {
        let mut conn = self.conn().await?;
        let ids: Vec<String> = conn.lrange(CUST_INDEX, 0, -1).await?;
        let mut customers = Vec::new();
        for id in ids {
            let json: Option<String> = conn.get(format!("{CUST_KEY}{id}")).await?;
            if let Some(json) = json {
                let customer = serde_json::from_str(&json).map_err(|err| {
                    ControlPlaneError::Redis(redis::RedisError::from((
                        redis::ErrorKind::ResponseError,
                        "corrupt customer record",
                        format!("{json}: {err}"),
                    )))
                })?;
                customers.push(customer);
            }
        }
        Ok(customers)
    }

    /// Delete a customer. The edge drops the WG peer separately (via
    /// `wg set`); this removes the record only.
    pub async fn delete(&self, id: &str) -> Result<(), ControlPlaneError> {
        let mut conn = self.conn().await?;
        let removed: i64 = conn.del(format!("{CUST_KEY}{id}")).await?;
        if removed == 0 {
            return Err(ControlPlaneError::NotFound(id.to_string()));
        }
        let _: i64 = conn.lrem(CUST_INDEX, 1, id).await?;
        Ok(())
    }
}

/// Generate a WireGuard keypair. WireGuard keys are Curve25519
/// (x25519); the private key is a random 32-byte scalar, the public
/// key is the x25519 base-point multiplication.
pub fn generate_wg_keypair() -> (String, String) {
    use rand_core::OsRng;
    let secret = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);
    (B64.encode(public.as_bytes()), B64.encode(secret.to_bytes()))
}

// ── HTTP handlers ────────────────────────────────────────────────

#[handler]
async fn signup(Data(cp): Data<&ControlPlane>) -> Response {
    match cp.signup().await {
        Ok(resp) => Json(resp).with_status(StatusCode::CREATED).into_response(),
        Err(err) => {
            tracing::error!(error = %err, "signup failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn list_customers(Data(cp): Data<&ControlPlane>) -> Response {
    match cp.list().await {
        Ok(customers) => Json(customers).into_response(),
        Err(err) => {
            tracing::error!(error = %err, "list customers failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn delete_customer(Data(cp): Data<&ControlPlane>, Path(id): Path<String>) -> Response {
    match cp.delete(&id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(ControlPlaneError::NotFound(_)) => StatusCode::NOT_FOUND.into_response(),
        Err(err) => {
            tracing::error!(error = %err, id = %id, "delete customer failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Build the control-plane HTTP app.
pub fn app(cp: ControlPlane) -> impl Endpoint {
    Route::new()
        .at("/signup", post(signup))
        .at("/customers", poem::get(list_customers))
        .at("/customers/:id", poem::delete(delete_customer))
        .data(cp)
}

/// Entry point for the controlplane binary.
pub async fn controlplane_entry(redis_url: String, subnet: String) -> Result<(), std::io::Error> {
    let subnet = Subnet64::from_str(&subnet).map_err(std::io::Error::other)?;
    let cp = ControlPlane::new(&redis_url, subnet)
        .map_err(|err| std::io::Error::other(format!("control plane init: {err}")))?;
    poem::Server::new(poem::listener::TcpListener::bind("0.0.0.0:8081"))
        .run(app(cp))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subnet64_parses_and_hosts() {
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        assert_eq!(subnet.host_string(1), "2a01:4f8:c17:1::1");
        assert_eq!(subnet.host_string(2), "2a01:4f8:c17:1::2");
        assert_eq!(subnet.host_string(65536), "2a01:4f8:c17:1::1:0");
    }

    #[test]
    fn subnet72_parses_and_hosts() {
        // A /72 slice of a shared /64: the box's network prefix is 9
        // bytes, hosts live in the last 7 bytes.
        let subnet = Subnet64::from_str("2a01:4f8:c17:1:ab00::/72").unwrap();
        assert_eq!(subnet.host_string(1), "2a01:4f8:c17:1:ab00::1");
        assert_eq!(subnet.host_string(2), "2a01:4f8:c17:1:ab00::2");
        assert_eq!(subnet.host_string(256), "2a01:4f8:c17:1:ab00::100");
    }

    #[test]
    fn subnet96_parses_and_hosts() {
        // A /96 slice: 12 prefix bytes, hosts live in the last 4.
        let subnet = Subnet64::from_str("2a01:4f8:c17:1:abcd::/96").unwrap();
        assert_eq!(subnet.host_string(1), "2a01:4f8:c17:1:abcd::1");
        assert_eq!(subnet.host_string(2), "2a01:4f8:c17:1:abcd::2");
    }

    #[test]
    fn subnet_rejects_bad_prefix_lengths() {
        assert!(Subnet64::from_str("2a01:4f8:c17:1::/63").is_err());
        assert!(Subnet64::from_str("2a01:4f8:c17:1::/68").is_err()); // not byte-aligned
        assert!(Subnet64::from_str("2a01:4f8:c17:1::/120").is_err()); // /120+ too fine
        assert!(Subnet64::from_str("2a01:4f8:c17:1::").is_err()); // no /len
    }

    #[test]
    fn subnet64_rejects_host_bits() {
        assert!(Subnet64::from_str("2a01:4f8:c17:1::2/64").is_err());
        assert!(Subnet64::from_str("2a01:4f8:c17:1:ab00::2/72").is_err());
        assert!(Subnet64::from_str("not-an-ip/64").is_err());
    }

    #[test]
    fn wg_keypair_round_trips() {
        let (pubkey, privkey) = generate_wg_keypair();
        assert_eq!(B64.decode(&pubkey).unwrap().len(), 32);
        assert_eq!(B64.decode(&privkey).unwrap().len(), 32);
        // Deterministic derivation: pub = x25519(priv, basepoint).
        let priv_bytes: [u8; 32] = B64.decode(&privkey).unwrap().try_into().unwrap();
        let secret = StaticSecret::from(priv_bytes);
        let public = PublicKey::from(&secret);
        assert_eq!(B64.encode(public.as_bytes()), pubkey);
    }

    /// Live store test against a real Redis. Skipped unless
    /// REDIS_URL is set (the nix devshell provides it; CI does not
    /// run a Redis). Proves the full signup→list→delete round trip
    /// against the actual store, not just the pure logic.
    #[tokio::test]
    async fn redis_store_round_trip() {
        let url = match std::env::var("REDIS_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipping: REDIS_URL not set");
                return;
            }
        };
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let cp = ControlPlane::new(&url, subnet).unwrap();

        let first = cp.signup().await.expect("first signup");
        let second = cp.signup().await.expect("second signup");
        assert_ne!(first.customer.ipv6, second.customer.ipv6);
        assert_eq!(first.customer.ipv6, "2a01:4f8:c17:1::2");
        assert_eq!(second.customer.ipv6, "2a01:4f8:c17:1::3");

        let customers = cp.list().await.expect("list");
        assert_eq!(customers.len(), 2);

        cp.delete(&first.customer.id).await.expect("delete first");
        let customers = cp.list().await.expect("list after delete");
        assert_eq!(customers.len(), 1);
        assert_eq!(customers[0].id, second.customer.id);

        cp.delete(&second.customer.id).await.expect("delete second");
        assert!(matches!(
            cp.delete(&second.customer.id).await,
            Err(ControlPlaneError::NotFound(_))
        ));
    }
}
