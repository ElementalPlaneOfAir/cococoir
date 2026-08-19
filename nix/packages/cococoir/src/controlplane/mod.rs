// SPDX-License-Identifier: AGPL-3.0-or-later
//! Control plane — the remote-access provisioning service.
//!
//! ADR-025: this is a *separate minimal service* from the client
//! dashboard. The dashboard manages household users on one server
//! (sqlite); this service manages *customers* on the edge (Redis).
//!
//! What it does (demo slice):
//!   - `POST /signup` — allocate the next `/128` from the box's
//!     routed subnet, generate the customer's WireGuard keypair, store
//!     the customer in Redis, add the customer's WG peer + live
//!     forwards, and return a complete tunnel config (the customer's
//!     private key + IPs + the edge's public key). The customer's box
//!     dials out to the edge with that key.
//!   - `GET /customers` — list.
//!   - `DELETE /customers/:id` — remove (disruption-free: the control
//!     plane drops the WG peer via `wg set`, no restart).
//!   - `GET /pubkey` — the edge's own WG public key (self-generated +
//!     persisted in Redis on first boot, so it is stable across
//!     restarts). Customer configs pull this instead of baking a
//!     static key.
//!
//! Storage is Redis. The state (customers, allocations, keys) is
//! recoverable — a lost allocation is rebuilt from the edge's WG
//! peers — so Redis's simplicity wins over a SQL store. Durability is
//! AOF + `appendfsync always` (configured in the NixOS module),
//! deliberately not assumed.
//!
//! The `/128` allocation uses an atomic Redis counter (`INCR` on a
//! Lua-free single key — INCR is atomic in Redis). Host 1 is the
//! edge's own primary `/128`; customers start at host 2.

pub mod routing_config;
pub mod wg;
pub use routing_config::{RoutingTable, WgPeer};
pub use wg::{RealWgClient, WgClient, WgError};

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

use crate::forwarder::{Config, Forward, Forwarder, Proto};

/// Redis key namespace for the control plane.
const CUST_KEY: &str = "cococoir:customer:";
/// Redis key holding the next free host index within the box subnet.
const ALLOC_COUNTER: &str = "cococoir:alloc:next";
/// Redis key holding the next free WG tunnel address index.
const WG_ALLOC_COUNTER: &str = "cococoir:wg:next";
/// Redis key holding the list of customer ids.
const CUST_INDEX: &str = "cococoir:customers";
/// Redis key holding the edge's own WG private key. Generated once on
/// first boot and persisted (AOF + appendfsync always), so the edge's
/// identity survives restarts and customer configs keep working.
const EDGE_PRIV_KEY: &str = "cococoir:edge:private-key";

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

/// The WireGuard tunnel network the edge and customers share, e.g.
/// `10.10.0.0/24`. Host 1 is the edge itself; customers get hosts
/// 2+ (same index as their `/128`).
#[derive(Debug, Clone)]
pub struct WgSubnet {
    /// The network prefix bytes (leading `(32 - prefix_len) / 8`
    /// bytes; host bits zero).
    prefix: Vec<u8>,
    prefix_len: u8,
}

impl WgSubnet {
    pub fn from_str(s: &str) -> Result<Self, String> {
        let (addr_str, len_str) = s
            .rsplit_once('/')
            .ok_or_else(|| format!("invalid wg subnet {s}: missing /len"))?;
        let prefix_len: u8 = len_str
            .parse()
            .map_err(|_| format!("invalid prefix length in {s}"))?;
        if prefix_len < 8 || prefix_len > 30 || prefix_len % 8 != 0 {
            return Err(format!(
                "{s}: wg prefix must be byte-aligned and between /8 and /30 (was /{prefix_len})"
            ));
        }
        let addr: std::net::Ipv4Addr = addr_str
            .parse()
            .map_err(|err| format!("invalid wg subnet {addr_str}: {err}"))?;
        let octets = addr.octets();
        let prefix_bytes = (prefix_len / 8) as usize;
        if octets[prefix_bytes..].iter().any(|&b| b != 0) {
            return Err(format!("{s} is not a /{prefix_len} (host bits set)"));
        }
        Ok(Self {
            prefix: octets[..prefix_bytes].to_vec(),
            prefix_len,
        })
    }

    /// The tunnel address for a host index (1 = edge, 2+ = customers).
    pub fn host_string(&self, index: u64) -> String {
        let host_bytes = 4 - self.prefix.len();
        let max_host = if host_bytes >= 4 {
            u32::MAX as u64
        } else {
            (1u64 << (host_bytes * 8)) - 1
        };
        assert!(index <= max_host, "wg host index {index} exceeds /{} capacity", self.prefix_len);
        let mut octets = [0u8; 4];
        octets[..self.prefix.len()].copy_from_slice(&self.prefix);
        let idx_bytes = (index as u32).to_be_bytes();
        octets[self.prefix.len()..].copy_from_slice(&idx_bytes[4 - host_bytes..]);
        std::net::Ipv4Addr::from(octets).to_string()
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Customer {
    pub id: String,
    pub ipv6: String,
    /// The customer's WG tunnel address (dest for the edge's forwards).
    pub wg_ip: String,
    pub wg_public_key: String,
}

/// The signup response. The customer's private key is returned ONCE —
/// after this it is gone from the service (only the public key is
/// stored). The edge's public key is included so the customer can
/// configure its WG peer for the edge — the response is a complete,
/// ready-to-install tunnel config.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SignupResponse {
    pub customer: Customer,
    pub wg_private_key: String,
    pub edge_public_key: String,
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
    #[error("forwarder: {0}")]
    Forward(String),
    #[error("wg: {0}")]
    Wg(#[from] WgError),
}

/// The control plane. Holds the Redis connection, the subnets (edge
/// routed IPv6 + the WireGuard tunnel net), and the WG kernel client.
#[derive(Clone)]
pub struct ControlPlane {
    client: redis::Client,
    subnet: Arc<Subnet64>,
    wg_subnet: Arc<WgSubnet>,
    wg: Arc<dyn WgClient>,
}

impl ControlPlane {
    /// Connect to Redis and derive the box subnet + WG tunnel net.
    pub fn new(redis_url: &str, subnet: Subnet64, wg_subnet: WgSubnet) -> Result<Self, ControlPlaneError> {
        let client = redis::Client::open(redis_url)?;
        Ok(Self {
            client,
            subnet: Arc::new(subnet),
            wg_subnet: Arc::new(wg_subnet),
            wg: Arc::new(RealWgClient::new()),
        })
    }

    /// Like [`ControlPlane::new`] but with an injected WG client — for
    /// tests that must not touch the real kernel interface.
    pub fn with_wg(
        redis_url: &str,
        subnet: Subnet64,
        wg_subnet: WgSubnet,
        wg: Arc<dyn WgClient>,
    ) -> Result<Self, ControlPlaneError> {
        let client = redis::Client::open(redis_url)?;
        Ok(Self {
            client,
            subnet: Arc::new(subnet),
            wg_subnet: Arc::new(wg_subnet),
            wg,
        })
    }

    async fn conn(&self) -> Result<redis::aio::Connection, ControlPlaneError> {
        Ok(self.client.get_async_connection().await?)
    }

    /// The edge's own WireGuard public key. Generated and persisted on
    /// first call (in Redis, durable via AOF + appendfsync always), and
    /// the private key is installed into the running `wg0` interface so
    /// the edge answers customer handshakes. Subsequent calls return
    /// the same key — the edge's identity is stable across restarts.
    pub async fn edge_public_key(&self) -> Result<String, ControlPlaneError> {
        let mut conn = self.conn().await?;
        let existing: Option<String> = conn.get(EDGE_PRIV_KEY).await?;
        let had_existing = existing.is_some();
        let (private_key, generated_now) = match existing {
            Some(key) => (key, false),
            None => {
                let (_public, private) = generate_wg_keypair();
                // SETNX so concurrent first-boots cannot disagree; a
                // lost race uses the winner's key.
                let set: bool = conn.set_nx(EDGE_PRIV_KEY, &private).await?;
                (private, set)
            }
        };
        // Install the private key into wg0: when we generated it this
        // boot, or when a restart between wg-quick up and this boot
        // left the interface on the wrong key.
        if generated_now || had_existing {
            self.wg
                .set_private_key(&private_key)
                .map_err(ControlPlaneError::Wg)?;
        }
        let priv_bytes: [u8; 32] = B64
            .decode(&private_key)
            .expect("persisted edge key is base64")
            .try_into()
            .map_err(|_| ControlPlaneError::Wg(WgError::Io(std::io::Error::other(
                "edge private key is not 32 bytes",
            ))))?;
        let secret = StaticSecret::from(priv_bytes);
        Ok(B64.encode(PublicKey::from(&secret).as_bytes()))
    }

    /// Allocate the next `/128` + WG tunnel address, create a
    /// customer, write the routing table, and add the edge's forwards
    /// for the customer's `:80` and `:443` — all live, without
    /// touching existing forwards. Returns the signup response.
    pub async fn signup(
        &self,
        table: &RoutingTable,
        forwarder: &Forwarder,
    ) -> Result<SignupResponse, ControlPlaneError> {
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
        let wg_ip = self.wg_subnet.host_string(index as u64);

        let id = uuid::Uuid::new_v4().to_string();
        let (public_key, private_key) = generate_wg_keypair();
        let customer = Customer {
            id: id.clone(),
            ipv6: ipv6.clone(),
            wg_ip: wg_ip.clone(),
            wg_public_key: public_key,
        };

        let key = format!("{CUST_KEY}{id}");
        let json = serde_json::to_string(&customer).expect("customer serializes");
        // The set is conditional on the id being new; a fresh uuid
        // cannot collide, but assert it anyway (defensive).
        let set: bool = conn.set_nx(&key, json).await?;
        assert!(set, "fresh customer id must not collide");
        let _: i64 = conn.rpush(CUST_INDEX, &id).await?;

        // Live wiring: routing table + forwarder listeners + WG peer.
        table.upsert(
            ipv6.parse().expect("allocated /128 parses"),
            WgPeer {
                wg_ip: wg_ip.clone(),
                wg_public_key: customer.wg_public_key.clone(),
            },
        );
        self.wg
            .add_peer(&wg_ip, &customer.wg_public_key)
            .map_err(|err| ControlPlaneError::Wg(err))?;
        for port in [80u16, 443] {
            let fwd = Forward {
                listen_addr: format!("[{ipv6}]:{port}"),
                proto: Proto::Tcp,
                dest_addr: format!("{wg_ip}:{port}"),
            };
            forwarder.add_forward(&fwd).await.map_err(|err| {
                let addr = &fwd.listen_addr;
                ControlPlaneError::Forward(format!("add forward {addr}: {err}"))
            })?;
        }

        let edge_public_key = self.edge_public_key().await?;

        Ok(SignupResponse {
            customer,
            wg_private_key: private_key,
            edge_public_key,
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

    /// Boot-time reconciliation (obligatory, not optional): rebuild
    /// the routing table + live forwards from the durable store. Runs
    /// before the edge accepts traffic, so a crash never leaves a
    /// customer registered in Redis but not forwarded.
    pub async fn rehydrate(
        &self,
        table: &RoutingTable,
        forwarder: &Forwarder,
    ) -> Result<usize, ControlPlaneError> {
        let customers = self.list().await?;
        let mut count = 0usize;
        for customer in &customers {
            let ipv6: Ipv6Addr = match customer.ipv6.parse() {
                Ok(ip) => ip,
                Err(_) => {
                    tracing::error!(id = %customer.id, ipv6 = %customer.ipv6, "skipping corrupt customer");
                    continue;
                }
            };
            table.upsert(
                ipv6,
                WgPeer {
                    wg_ip: customer.wg_ip.clone(),
                    wg_public_key: customer.wg_public_key.clone(),
                },
            );
            if let Err(err) = self.wg.add_peer(&customer.wg_ip, &customer.wg_public_key) {
                tracing::error!(id = %customer.id, wg_ip = %customer.wg_ip, err = %err, "rehydrate wg add failed");
            }
            for port in [80u16, 443] {
                let fwd = Forward {
                    listen_addr: format!("[{}]:{port}", customer.ipv6),
                    proto: Proto::Tcp,
                    dest_addr: format!("{}:{port}", customer.wg_ip),
                };
                if let Err(err) = forwarder.add_forward(&fwd).await {
                    tracing::error!(id = %customer.id, addr = %fwd.listen_addr, err = %err, "rehydrate bind failed");
                }
            }
            count += 1;
        }
        tracing::info!(customers = count, forwards = %forwarder.stats().forwards.len(), "routing table rehydrated");
        Ok(count)
    }

    /// Delete a customer: remove the record, the routing table entry,
    /// and the live forwards. The WG peer itself is dropped via
    /// `wg set` separately (not yet wired).
    pub async fn delete(
        &self,
        id: &str,
        table: &RoutingTable,
        forwarder: &Forwarder,
    ) -> Result<(), ControlPlaneError> {
        let mut conn = self.conn().await?;
        let json: Option<String> = conn.get(format!("{CUST_KEY}{id}")).await?;
        let removed: i64 = conn.del(format!("{CUST_KEY}{id}")).await?;
        if removed == 0 {
            return Err(ControlPlaneError::NotFound(id.to_string()));
        }
        let _: i64 = conn.lrem(CUST_INDEX, 1, id).await?;

        if let Some(json) = json {
            if let Ok(customer) = serde_json::from_str::<Customer>(&json) {
                let ipv6: Ipv6Addr = customer.ipv6.parse().expect("stored /128 parses");
                table.remove(&ipv6);
                self.wg
                    .remove_peer(&customer.wg_public_key)
                    .map_err(|err| ControlPlaneError::Wg(err))?;
                for port in [80u16, 443] {
                    let fwd = Forward {
                        listen_addr: format!("[{}]:{port}", customer.ipv6),
                        proto: Proto::Tcp,
                        dest_addr: format!("{}:{port}", customer.wg_ip),
                    };
                    forwarder.remove_forward(&fwd);
                }
            }
        }
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

/// Application state: the control plane + the live routing table +
/// the forwarder it mutates. All three are process-lifetime, shared
/// via poem's `Data` extractor.
#[derive(Clone)]
pub struct AppState {
    pub cp: Arc<ControlPlane>,
    pub table: Arc<RoutingTable>,
    pub forwarder: Arc<Forwarder>,
}

#[handler]
async fn signup(Data(state): Data<&AppState>) -> Response {
    match state.cp.signup(&state.table, &state.forwarder).await {
        Ok(resp) => Json(resp).with_status(StatusCode::CREATED).into_response(),
        Err(err) => {
            tracing::error!(error = %err, "signup failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn list_customers(Data(state): Data<&AppState>) -> Response {
    match state.cp.list().await {
        Ok(customers) => Json(customers).into_response(),
        Err(err) => {
            tracing::error!(error = %err, "list customers failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn delete_customer(Data(state): Data<&AppState>, Path(id): Path<String>) -> Response {
    match state.cp.delete(&id, &state.table, &state.forwarder).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(ControlPlaneError::NotFound(_)) => StatusCode::NOT_FOUND.into_response(),
        Err(err) => {
            tracing::error!(error = %err, id = %id, "delete customer failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn edge_pubkey(Data(state): Data<&AppState>) -> Response {
    match state.cp.edge_public_key().await {
        Ok(pubkey) => Json(serde_json::json!({ "public_key": pubkey })).into_response(),
        Err(err) => {
            tracing::error!(error = %err, "edge pubkey failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Build the control-plane HTTP app.
pub fn app(state: AppState) -> impl Endpoint {
    Route::new()
        .at("/signup", post(signup))
        .at("/customers", poem::get(list_customers))
        .at("/customers/:id", poem::delete(delete_customer))
        .at("/pubkey", poem::get(edge_pubkey))
        .data(state)
}

/// Entry point for the controlplane binary.
pub async fn controlplane_entry(
    redis_url: String,
    subnet: String,
    wg_subnet: String,
) -> Result<(), std::io::Error> {
    let subnet = Subnet64::from_str(&subnet).map_err(std::io::Error::other)?;
    let wg_subnet = WgSubnet::from_str(&wg_subnet).map_err(std::io::Error::other)?;
    let cp = ControlPlane::new(&redis_url, subnet, wg_subnet)
        .map_err(|err| std::io::Error::other(format!("control plane init: {err}")))?;
    let forwarder = Forwarder::new_live(Config::default())
        .map_err(|err| std::io::Error::other(format!("forwarder init: {err}")))?;
    let state = AppState {
        cp: Arc::new(cp),
        table: Arc::new(RoutingTable::new()),
        forwarder: Arc::new(forwarder),
    };
    poem::Server::new(poem::listener::TcpListener::bind("0.0.0.0:8081"))
        .run(app(state))
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

    #[test]
    fn wg_subnet_parses_and_hosts() {
        let wg = WgSubnet::from_str("10.10.0.0/24").unwrap();
        assert_eq!(wg.host_string(1), "10.10.0.1");
        assert_eq!(wg.host_string(2), "10.10.0.2");
        assert_eq!(wg.host_string(255), "10.10.0.255");
    }

    #[test]
    fn wg_subnet_rejects_host_bits_and_bad_prefix() {
        assert!(WgSubnet::from_str("10.10.0.2/24").is_err());
        assert!(WgSubnet::from_str("10.0.0.0/7").is_err()); // not byte-aligned
        assert!(WgSubnet::from_str("10.0.0.0/31").is_err()); // /31 too fine
        assert!(WgSubnet::from_str("10.0.0.0").is_err()); // no /len
    }

    /// Live store + routing test against a real Redis. Skipped unless
    /// REDIS_URL is set (the nix devshell provides it; CI does not
    /// run a Redis). Proves the full signup→list→delete round trip
    /// against the actual store, including the routing table + live
    /// forwarder mutation.
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
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").unwrap();
        let wg = Arc::new(crate::controlplane::wg::MockWgClient::new());
        let cp = ControlPlane::with_wg(&url, subnet, wg_subnet, wg.clone()).unwrap();
        let table = RoutingTable::new();
        let forwarder = Forwarder::new_live(Config::default()).unwrap();

        let first = cp.signup(&table, &forwarder).await.expect("first signup");
        let second = cp.signup(&table, &forwarder).await.expect("second signup");
        assert_ne!(first.customer.ipv6, second.customer.ipv6);
        assert_eq!(first.customer.ipv6, "2a01:4f8:c17:1::2");
        assert_eq!(first.customer.wg_ip, "10.10.0.2");
        assert_eq!(second.customer.ipv6, "2a01:4f8:c17:1::3");
        assert_eq!(second.customer.wg_ip, "10.10.0.3");

        // The edge's public key is stable across signups (persisted,
        // not regenerated) and matches GET /pubkey — the customer can
        // configure its WG peer for the edge from the response.
        assert!(!first.edge_public_key.is_empty());
        assert_eq!(first.edge_public_key, second.edge_public_key);
        let pubkey = cp.edge_public_key().await.expect("edge pubkey");
        assert_eq!(pubkey, first.edge_public_key);
        // The edge private key was installed into the interface once
        // (on first generation), not per-signup.
        assert_eq!(wg.private_keys.lock().unwrap().len(), 1);

        // The routing table got both entries; the forwarder bound 4
        // live listeners (2 customers × 2 ports); the WG client added
        // both peers to the kernel interface.
        assert_eq!(table.len(), 2);
        assert_eq!(forwarder.stats().forwards.len(), 4);
        assert!(forwarder.stats().forwards.iter().all(|s| s.bound));
        assert_eq!(wg.added.lock().unwrap().len(), 2);

        let customers = cp.list().await.expect("list");
        assert_eq!(customers.len(), 2);

        cp.delete(&first.customer.id, &table, &forwarder).await.expect("delete first");
        assert_eq!(table.len(), 1);
        assert_eq!(forwarder.stats().forwards.len(), 2);
        assert_eq!(wg.removed.lock().unwrap().len(), 1);

        let customers = cp.list().await.expect("list after delete");
        assert_eq!(customers.len(), 1);
        assert_eq!(customers[0].id, second.customer.id);

        cp.delete(&second.customer.id, &table, &forwarder).await.expect("delete second");
        assert!(matches!(
            cp.delete(&second.customer.id, &table, &forwarder).await,
            Err(ControlPlaneError::NotFound(_))
        ));
        assert_eq!(table.len(), 0);
        assert_eq!(forwarder.stats().forwards.len(), 0);
    }
}
