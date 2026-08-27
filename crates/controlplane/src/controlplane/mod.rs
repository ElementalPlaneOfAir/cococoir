// SPDX-License-Identifier: AGPL-3.0-or-later
//! Control plane — the remote-access provisioning service.
//!
//! ADR-025: this is a *separate minimal service* from the client
//! dashboard. The dashboard manages household users on one server
//! (sqlite); this service manages *customers* on the edge (Redis).
//!
//! What it does (demo slice):
//!   - `POST /signup` — allocate the next `/128` from the box's
//!     routed subnet, store the customer in Redis, add the customer's
//!     WG peer + live forwards, and return the route + the edge's public
//!     key. The customer's box dials out to the edge with that key.
//!     The client supplies its own WG public key (ADR-025: the edge
//!     never holds a customer private key); the call is idempotent and
//!     rotates the peer key on an existing route.
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

pub mod auth;
pub mod dns;
pub mod secret;
pub mod wg;
pub use auth::{verify_token, AdminKey};
pub use dns::{
    customer_hostname, get_dns_api, reconcile_pass, remove_customer, resolve_aaaa,
    resolve_aaaa_boxed, upsert_customer, DnsApiClient, DnsError, HetznerDns, MockDnsApiClient,
};
pub use secret::{admin_key_hash, root_domain};
pub use wg::{RealWgClient, WgClient, WgError};

use std::net::Ipv6Addr;
use std::sync::Arc;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use cococoir_core::health::{HealthApi, StatusFunc};
use poem::Route;
use poem_openapi::param::Path;
use poem_openapi::payload::Json;
use poem_openapi::{ApiResponse, Object, OpenApi, OpenApiService};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};

use cococoir_core::forwarder::{Config, Forward, Forwarder, Proto};

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

/// The process's two singletons: the control plane (Redis-backed) and
/// the live forwarder. Both are process-lifetime — built once at boot,
/// never dropped — so they live as `'static` `OnceCell`s, not injected
/// `Arc`s (see `writing/human/lifetimes_in_rust.md`). The forwarder is
/// the in-process source of truth for live listeners; the control plane
/// mutates it directly at signup/delete and rehydrates it from Redis on
/// boot. `get_or_try_init` publishes only a *hydrated* value. Tests
/// `set()` their own instance to bypass hydration (mutually exclusive
/// with `get_or_try_init` on one cell).
static CONTROL_PLANE: tokio::sync::OnceCell<ControlPlane> = tokio::sync::OnceCell::const_new();
static FORWARDER: tokio::sync::OnceCell<Forwarder> = tokio::sync::OnceCell::const_new();

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
        assert!(
            index <= max_host,
            "wg host index {index} exceeds /{} capacity",
            self.prefix_len
        );
        let mut octets = [0u8; 4];
        octets[..self.prefix.len()].copy_from_slice(&self.prefix);
        let idx_bytes = (index as u32).to_be_bytes();
        octets[self.prefix.len()..].copy_from_slice(&idx_bytes[4 - host_bytes..]);
        std::net::Ipv4Addr::from(octets).to_string()
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, Object)]
pub struct Customer {
    /// The customer's username — their identity. Is the unique primary key on a per user basis.
    pub username: String,
    /// The customer's DNS hostname, e.g. `bob.interdim.net`.
    pub hostname: String,
    pub ipv6: String,
    /// The customer's WG tunnel address (dest for the edge's forwards).
    pub wg_ip: String,
    pub wg_public_key: String,
}

/// The signup response. The customer's private key never touches the
/// service — the client generates + persists it and sends only the
/// public key (ADR-025). The edge returns the route it allocated and
/// its own public key so the client can dial out.
#[derive(Debug, Serialize, Deserialize, Clone, Object)]
pub struct SignupResponse {
    pub customer: Customer,
    pub edge_public_key: String,
}

/// Whether a [`ControlPlane::signup`] call created a new route or
/// returned an existing one (idempotent no-op / key rotation).
#[derive(Debug)]
pub enum SignupOutcome {
    /// A fresh `/128` + WG tunnel was allocated.
    Created(SignupResponse),
    /// The username already existed; the response carries the existing
    /// route (unchanged `wg_ip`/`/128`), with the WG peer re-ensured or
    /// rotated to the supplied key.
    Existing(SignupResponse),
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
    #[error("dns: {0}")]
    Dns(#[from] DnsError),
    #[error("invalid username: {0}")]
    InvalidUsername(String),
    #[error("invalid wireguard public key: {0}")]
    InvalidPubkey(String),
    #[error("username already taken: {0}")]
    Duplicate(String),
}

/// The control plane. Holds the Redis connection, the subnets (edge
/// routed IPv6 + the WireGuard tunnel net), and `'static` references
/// to the WG + DNS clients.
///
/// Not `Clone`, and the clients are `&'static` not `Arc`: the control
/// plane is a process-lifetime singleton (`OnceCell` global), consumed
/// only as `&'static ControlPlane` — `Copy`, not cloned. See
/// `writing/human/lifetimes_in_rust.md`.
pub struct ControlPlane {
    client: redis::Client,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
    /// The domain customer hostnames live under. Injected (not read
    /// from the global [`secret::SECRETS`]) so tests can pass any
    /// domain without touching the boot-only secrets LazyLock.
    root_domain: &'static str,
    wg: &'static dyn WgClient,
    dns: &'static dyn DnsApiClient,
}

impl ControlPlane {
    /// Connect to Redis and derive the box subnet + WG tunnel net. The
    /// WG and DNS clients are the real ones.
    pub fn new(
        redis_url: &str,
        subnet: Subnet64,
        wg_subnet: WgSubnet,
    ) -> Result<Self, ControlPlaneError> {
        let client = redis::Client::open(redis_url)?;
        Ok(Self {
            client,
            subnet,
            wg_subnet,
            root_domain: secret::root_domain(),
            wg: &*wg::REAL_WG_CLIENT,
            dns: get_dns_api(),
        })
    }

    /// Like [`ControlPlane::new`] but with injected WG + DNS clients —
    /// for tests that must not touch the real kernel interface or the
    /// real DNS provider. The mocks must outlive the process (leak
    /// them in tests; `&'static` is the process-lifetime vehicle).
    /// `root_domain` is injected too (it is `'static`), so a test
    /// never forces the boot-only [`secret::SECRETS`] LazyLock.
    pub fn with_deps(
        redis_url: &str,
        subnet: Subnet64,
        wg_subnet: WgSubnet,
        root_domain: &'static str,
        wg: &'static dyn WgClient,
        dns: &'static dyn DnsApiClient,
    ) -> Result<Self, ControlPlaneError> {
        let client = redis::Client::open(redis_url)?;
        Ok(Self {
            client,
            subnet,
            wg_subnet,
            root_domain,
            wg,
            dns,
        })
    }

    async fn conn(&self) -> Result<redis::aio::Connection, ControlPlaneError> {
        Ok(self.client.get_async_connection().await?)
    }

    /// Ensure the edge's WG private key exists in Redis (generate +
    /// persist on first call via SETNX, so concurrent first-boots agree
    /// on one winner) and return the stored key. Pure storage access —
    /// no kernel side-effect.
    async fn ensure_edge_key(&self) -> Result<String, ControlPlaneError> {
        let mut conn = self.conn().await?;
        if let Some(key) = conn.get(EDGE_PRIV_KEY).await? {
            return Ok(key);
        }
        let (_public, private) = generate_wg_keypair();
        let _: bool = conn.set_nx(EDGE_PRIV_KEY, &private).await?;
        let stored: Option<String> = conn.get(EDGE_PRIV_KEY).await?;
        stored.ok_or_else(|| {
            ControlPlaneError::Redis(redis::RedisError::from((
                redis::ErrorKind::ResponseError,
                "edge key missing after ensure",
                "SETNX reported success but read-back was empty".to_string(),
            )))
        })
    }

    /// The edge's own WireGuard public key, derived from the persisted
    /// private key. Pure getter — does not touch the kernel — so it is
    /// safe to call per-signup and from `GET /pubkey`. The edge's
    /// identity is stable across restarts because the private key is
    /// durable in Redis.
    pub async fn edge_public_key(&self) -> Result<String, ControlPlaneError> {
        let private_key = self.ensure_edge_key().await?;
        let priv_bytes: [u8; 32] = B64
            .decode(&private_key)
            .expect("persisted edge key is base64")
            .try_into()
            .map_err(|_| {
                ControlPlaneError::Wg(WgError::Io(std::io::Error::other(
                    "edge private key is not 32 bytes",
                )))
            })?;
        let secret = StaticSecret::from(priv_bytes);
        Ok(B64.encode(PublicKey::from(&secret).as_bytes()))
    }

    /// Boot-time: ensure the edge identity exists and install its
    /// private key into the running `wg0` interface, so the edge answers
    /// customer handshakes and any throwaway key `wg-quick up` left
    /// there is replaced. Called once by [`init_globals`], not
    /// per-signup.
    pub async fn install_edge_identity(&self) -> Result<(), ControlPlaneError> {
        let private_key = self.ensure_edge_key().await?;
        self.wg
            .set_private_key(&private_key)
            .map_err(ControlPlaneError::Wg)?;
        Ok(())
    }

    /// Allocate the next `/128` + WG tunnel address, create a
    /// customer, write the routing table, add the edge's forwards
    /// for the customer's `:80` and `:443`, and provision the
    /// customer's DNS AAAA records — all live, without touching
    /// existing forwards. Returns the signup response. Reads the
    /// process routing table + forwarder globals.
    ///
    /// DNS runs LAST and is non-fatal: the customer is reachable at
    /// their `/128` regardless, and the background reconcile loop
    /// self-heals a failed record.
    pub async fn signup(
        &self,
        username: &str,
        public_key: &str,
    ) -> Result<SignupOutcome, ControlPlaneError> {
        validate_username(username)?;
        validate_wg_pubkey(public_key)?;
        let forwarder = forwarder();
        let mut conn = self.conn().await?;
        let key = format!("{CUST_KEY}{username}");
        let existing: Option<String> = conn.get(&key).await?;
        let edge_public_key = self.edge_public_key().await?;

        // Idempotent / rotate path: the route already exists.
        if let Some(json) = existing {
            let mut customer: Customer = serde_json::from_str(&json).map_err(|err| {
                ControlPlaneError::Redis(redis::RedisError::from((
                    redis::ErrorKind::ResponseError,
                    "corrupt customer record",
                    format!("{json}: {err}"),
                )))
            })?;
            if customer.wg_public_key == public_key {
                // Same key: idempotent no-op. Re-ensure the peer (kernel
                // add_peer is idempotent); the `/128`+`wg_ip` are kept.
                if let Err(err) = self.wg.add_peer(&customer.wg_ip, public_key) {
                    tracing::error!(username = %username, err = %err, "signup idempotent: wg re-add failed");
                }
            } else {
                // Different key: rotate. Remove the old peer first — two
                // peers sharing the `/32` allowed-ips would be ambiguous —
                // then add the new key on the SAME route (the forwarder
                // dest `wg_ip` is unchanged). Persist the new pubkey.
                if let Err(err) = self.wg.remove_peer(&customer.wg_public_key) {
                    tracing::error!(username = %username, err = %err, "signup rotate: wg peer removal failed");
                }
                self.wg.add_peer(&customer.wg_ip, public_key)?;
                customer.wg_public_key = public_key.to_string();
                let updated = serde_json::to_string(&customer).expect("customer serializes");
                conn.set::<_, _, ()>(&key, updated).await?;
            }
            return Ok(SignupOutcome::Existing(SignupResponse {
                customer,
                edge_public_key,
            }));
        }

        // Fresh allocation. Existence is checked BEFORE allocating, so a
        // repeat signup never burns a `/128` (the old INCR-before-check
        // order wasted an index even on the Duplicate error).
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

        let hostname = customer_hostname(username, self.root_domain);
        let customer = Customer {
            username: username.to_string(),
            hostname: hostname.clone(),
            ipv6: ipv6.clone(),
            wg_ip: wg_ip.clone(),
            wg_public_key: public_key.to_string(),
        };

        let json = serde_json::to_string(&customer).expect("customer serializes");
        // Uniqueness is structural: the username IS the Redis key, so a
        // concurrent signup for the same username collides here.
        let set: bool = conn.set_nx(&key, json).await?;
        if !set {
            return Err(ControlPlaneError::Duplicate(username.to_string()));
        }
        let _: i64 = conn.rpush(CUST_INDEX, username).await?;

        // Live wiring: WG peer + forwarder listeners. The store entry is
        // committed before wiring, so a crash mid-wiring leaves a record
        // that rehydrate wires up on next boot. A *wiring* failure, by
        // contrast, rolls the store entry back: the username and /128
        // must not stay burned when the peer/forward could not be
        // created.
        if let Err(err) = self.wg.add_peer(&wg_ip, public_key) {
            self.rollback_signup(&mut conn, forwarder, username, &customer).await;
            return Err(ControlPlaneError::Wg(err));
        }
        for port in [80u16, 443] {
            let fwd = Forward {
                listen_addr: format!("[{ipv6}]:{port}"),
                proto: Proto::Tcp,
                dest_addr: format!("{wg_ip}:{port}"),
            };
            if let Err(err) = forwarder.add_forward(&fwd).await {
                self.rollback_signup(&mut conn, forwarder, username, &customer).await;
                let addr = &fwd.listen_addr;
                return Err(ControlPlaneError::Forward(format!("add forward {addr}: {err}")));
            }
        }

        // DNS last, non-fatal: the reconcile loop self-heals failures.
        if let Err(err) = upsert_customer(
            self.dns,
            username,
            ipv6.parse().expect("allocated /128 parses"),
            self.root_domain,
        )
        .await
        {
            tracing::error!(username = %username, err = %err, "signup: dns upsert failed (customer reachable at /128; reconcile will self-heal)");
        }

        Ok(SignupOutcome::Created(SignupResponse {
            customer,
            edge_public_key,
        }))
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
        forwarder: &Forwarder,
    ) -> Result<usize, ControlPlaneError> {
        let customers = self.list().await?;
        let mut count = 0usize;
        for customer in &customers {
            // Parse as a validity gate: a corrupt /128 is skipped loudly,
            // never panicked on.
            if customer.ipv6.parse::<Ipv6Addr>().is_err() {
                tracing::error!(username = %customer.username, ipv6 = %customer.ipv6, "skipping corrupt customer");
                continue;
            }
            if let Err(err) = self.wg.add_peer(&customer.wg_ip, &customer.wg_public_key) {
                tracing::error!(username = %customer.username, wg_ip = %customer.wg_ip, err = %err, "rehydrate wg add failed");
            }
            for port in [80u16, 443] {
                let fwd = Forward {
                    listen_addr: format!("[{}]:{port}", customer.ipv6),
                    proto: Proto::Tcp,
                    dest_addr: format!("{}:{port}", customer.wg_ip),
                };
                if let Err(err) = forwarder.add_forward(&fwd).await {
                    tracing::error!(username = %customer.username, addr = %fwd.listen_addr, err = %err, "rehydrate bind failed");
                }
            }
            count += 1;
        }
        tracing::info!(customers = count, forwards = %forwarder.stats().forwards.len(), "live forwards rehydrated");
        Ok(count)
    }

    /// Delete a customer: unwire the WG peer + live forwards + DNS AAAA
    /// records, then remove the store entry. Unwiring comes FIRST and is
    /// best-effort: the store entry is the durable source `rehydrate`
    /// reads, so it must be the last thing removed — if unwiring fails
    /// mid-way and the entry were already gone, the orphaned listeners
    /// would be unfixable on any future boot.
    pub async fn delete(&self, username: &str) -> Result<(), ControlPlaneError> {
        let forwarder = forwarder();
        let mut conn = self.conn().await?;
        let key = format!("{CUST_KEY}{username}");
        let json: Option<String> = conn.get(&key).await?;
        let Some(json) = json else {
            return Err(ControlPlaneError::NotFound(username.to_string()));
        };
        let customer: Customer = match serde_json::from_str(&json) {
            Ok(customer) => customer,
            Err(err) => {
                // Corrupt record: we cannot unwire it (its data is gone),
                // but the store entry must still drop so the username is
                // freed and rehydrate stops resurrecting it.
                tracing::error!(username = %username, err = %err, "delete: corrupt customer record; removing entry without unwiring");
                let _: i64 = conn.del(&key).await?;
                let _: i64 = conn.lrem(CUST_INDEX, 1, username).await?;
                return Ok(());
            }
        };

        // Unwire first, best-effort: a WG or DNS failure is logged, never
        // fatal, so the store entry is always removed.
        if let Err(err) = self.wg.remove_peer(&customer.wg_public_key) {
            tracing::error!(username = %username, err = %err, "delete: wg peer removal failed; stale peer may remain");
        }
        for port in [80u16, 443] {
            let fwd = Forward {
                listen_addr: format!("[{}]:{port}", customer.ipv6),
                proto: Proto::Tcp,
                dest_addr: format!("{}:{port}", customer.wg_ip),
            };
            forwarder.remove_forward(&fwd);
        }
        // DNS removal is best-effort: the customer is already gone from
        // the tunnel; a provider outage leaves a stale record that the
        // reconcile loop cannot prune (it only re-applies for existing
        // customers). Logged loudly, never silent.
        if let Err(err) = remove_customer(self.dns, username, self.root_domain).await {
            tracing::error!(username = %username, err = %err, "delete: dns remove failed; stale records may remain");
        }

        // Store last.
        let _: i64 = conn.del(&key).await?;
        let _: i64 = conn.lrem(CUST_INDEX, 1, username).await?;
        Ok(())
    }

    /// Best-effort rollback of a failed [`ControlPlane::signup`]: drop
    /// the store entry and unwire whatever was partially created. Runs
    /// after the record is committed but a live-wiring step failed, so
    /// the username + /128 are freed and `rehydrate` cannot resurrect a
    /// zombie (whose private key would be unrecoverable). Never fails the
    /// original error; logs any cleanup failure.
    async fn rollback_signup(
        &self,
        conn: &mut redis::aio::Connection,
        forwarder: &Forwarder,
        username: &str,
        customer: &Customer,
    ) {
        let _: i64 = match conn.del(format!("{CUST_KEY}{username}")).await {
            Ok(n) => n,
            Err(err) => {
                tracing::error!(username = %username, err = %err, "signup rollback: store delete failed; zombie record may persist");
                return;
            }
        };
        let _: i64 = match conn.lrem(CUST_INDEX, 1, username).await {
            Ok(n) => n,
            Err(err) => {
                tracing::error!(username = %username, err = %err, "signup rollback: index removal failed");
                return;
            }
        };
        if let Err(err) = self.wg.remove_peer(&customer.wg_public_key) {
            tracing::error!(username = %username, err = %err, "signup rollback: wg peer removal failed");
        }
        for port in [80u16, 443] {
            forwarder.remove_forward(&Forward {
                listen_addr: format!("[{}]:{port}", customer.ipv6),
                proto: Proto::Tcp,
                dest_addr: format!("{}:{port}", customer.wg_ip),
            });
        }
    }

    /// One DNS reconcile pass: verify each customer's two AAAA records
    /// against real resolution (1.1.1.1) and re-apply mismatches.
    pub async fn reconcile_dns_once(&self) -> Result<usize, ControlPlaneError> {
        let customers = self.list().await?;
        let pairs: Vec<(String, Ipv6Addr)> = customers
            .into_iter()
            .filter_map(|c| c.ipv6.parse().ok().map(|ip: Ipv6Addr| (c.username, ip)))
            .collect();
        Ok(reconcile_pass(self.dns, &pairs, resolve_aaaa_boxed, self.root_domain).await)
    }
}

/// Generate a WireGuard keypair. WireGuard keys are Curve25519
/// (x25519); the private key is a random 32-byte scalar, the public
/// key is the x25519 base-point multiplication. Delegates to the shared
/// `cococoir_core::wg` helper so the crypto lives in one place (the
/// client uses the same code).
pub fn generate_wg_keypair() -> (String, String) {
    cococoir_core::wg::generate_keypair()
}

/// Validate a signup username as a DNS label, because the username
/// becomes a hostname (`{username}.{DOMAIN}`). Lowercase alphanumeric +
/// hyphen, not starting/ending with hyphen, no `--` (punycode reserve).
pub fn validate_username(username: &str) -> Result<(), ControlPlaneError> {
    let ok = !username.is_empty()
        && username.len() <= 63
        && !username.starts_with('-')
        && !username.ends_with('-')
        && !username.contains("--")
        && username
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if ok {
        Ok(())
    } else {
        Err(ControlPlaneError::InvalidUsername(username.to_string()))
    }
}

/// Validate a client-supplied WireGuard public key: a well-formed WG
/// public key is 32 bytes of base64. The kernel re-validates on `wg
/// set`; this is a cheap structural gate so a bad key fails before any
/// allocation or wiring.
pub fn validate_wg_pubkey(public_key: &str) -> Result<(), ControlPlaneError> {
    let ok = B64.decode(public_key).map(|b| b.len() == 32).unwrap_or(false);
    if ok {
        Ok(())
    } else {
        Err(ControlPlaneError::InvalidPubkey(public_key.to_string()))
    }
}

/// The process's forwarder. Panics if not initialized.
pub fn forwarder() -> &'static Forwarder {
    FORWARDER.get().expect("forwarder not initialized")
}

/// The process's control plane. Panics if not initialized.
pub fn control_plane() -> &'static ControlPlane {
    CONTROL_PLANE.get().expect("control plane not initialized")
}

/// Initialize the process globals, hydrating the live forwarder from
/// Redis before it becomes visible. Order matters: forwarder → control
/// plane → rehydrate (rehydrate needs the control plane's Redis
/// connection and the forwarder to bind into). Each `get_or_try_init`
/// returns `Err` on unreachable Redis rather than panicking, so a boot
/// or test that can't reach Redis fails cleanly. Tests bypass this
/// entirely by `set()`-ing their own instances.
pub async fn init_globals(
    redis_url: &str,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
) -> Result<(), ControlPlaneError> {
    // DNS config is process config: a missing zone/token is a boot
    // error, never a first-signup surprise. Forcing the `LazyLock`
    // resolves the secrets + builds the DNS client now.
    let _ = secret::root_domain();
    let _ = get_dns_api();
    FORWARDER
        .get_or_try_init(|| async {
            Forwarder::new_live(Config::default())
                .map_err(|err| ControlPlaneError::Forward(format!("forwarder init: {err}")))
        })
        .await?;
    CONTROL_PLANE
        .get_or_try_init(|| async {
            let cp = ControlPlane::new(redis_url, subnet, wg_subnet)?;
            cp.install_edge_identity().await?;
            Ok::<ControlPlane, ControlPlaneError>(cp)
        })
        .await?;
    // Obligatory reconcile-on-boot: rebuild the live forwards from the
    // durable store before the edge accepts traffic, so a crash never
    // leaves a customer registered in Redis but not forwarded.
    control_plane().rehydrate(forwarder()).await?;
    Ok(())
}

// ── HTTP API ─────────────────────────────────────────────────────

/// The HTTP API is a poem-openapi service (see `health.rs` for the
/// pattern): operations are `#[oai]` methods, so the OpenAPI v3 spec is
/// derived from the code ("compiles ⟹ spec-correct"). The handlers read
/// the process singletons directly — no `AppState`, they are `'static`.
/// Every operation except `/pubkey` takes an [`AdminKey`] arg, so the
/// spec declares the bearer scheme and the Authorize button in swagger
/// works.

/// The signup request body: the username that becomes the customer's
/// DNS hostname, plus the customer's WireGuard public key (the client
/// generates + holds the private key; the edge stores only the public
/// key — ADR-025).
#[derive(Debug, Deserialize, Object)]
pub struct SignupRequest {
    pub username: String,
    pub public_key: String,
}

/// `/pubkey` response: the edge's own WG public key.
#[derive(Debug, Serialize, Deserialize, Object)]
pub struct PubkeyResponse {
    pub public_key: String,
}

/// Status + body for `POST /signup`.
#[derive(ApiResponse)]
enum SignupApiResponse {
    /// Customer created.
    #[oai(status = "201")]
    Created(Json<SignupResponse>),
    /// Customer already existed (idempotent no-op or key rotation).
    #[oai(status = "200")]
    Ok(Json<SignupResponse>),
    /// Invalid username or public key.
    #[oai(status = "400")]
    BadRequest(Json<String>),
    /// Username already taken (concurrent race).
    #[oai(status = "409")]
    Conflict(Json<String>),
    /// Internal error.
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Status + body for `GET /customers`.
#[derive(ApiResponse)]
enum ListApiResponse {
    #[oai(status = "200")]
    Ok(Json<Vec<Customer>>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Status + body for `DELETE /customers/:username`.
#[derive(ApiResponse)]
enum DeleteApiResponse {
    #[oai(status = "204")]
    NoContent,
    #[oai(status = "404")]
    NotFound(Json<String>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Status + body for `GET /pubkey`.
#[derive(ApiResponse)]
enum PubkeyApiResponse {
    #[oai(status = "200")]
    Ok(Json<PubkeyResponse>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// The control-plane API. Unit struct — reads the process globals.
struct ControlPlaneApi;

#[OpenApi]
impl ControlPlaneApi {
    /// Create a customer (allocate a /128, forwards, DNS) or, if the
    /// username already exists, re-ensure / rotate the WG peer on the
    /// existing route. The client supplies its own WG public key; the
    /// edge never sees the private key.
    #[oai(path = "/signup", method = "post")]
    async fn signup(
        &self,
        _auth: AdminKey,
        Json(req): Json<SignupRequest>,
    ) -> SignupApiResponse {
        match control_plane()
            .signup(&req.username, &req.public_key)
            .await
        {
            Ok(SignupOutcome::Created(resp)) => SignupApiResponse::Created(Json(resp)),
            Ok(SignupOutcome::Existing(resp)) => SignupApiResponse::Ok(Json(resp)),
            Err(ControlPlaneError::InvalidUsername(username)) => {
                tracing::warn!(username = %username, "signup: invalid username");
                SignupApiResponse::BadRequest(Json("invalid username".to_string()))
            }
            Err(ControlPlaneError::InvalidPubkey(_)) => {
                tracing::warn!("signup: invalid wireguard public key");
                SignupApiResponse::BadRequest(Json("invalid wireguard public key".to_string()))
            }
            Err(ControlPlaneError::Duplicate(username)) => {
                tracing::warn!(username = %username, "signup: username taken");
                SignupApiResponse::Conflict(Json("username already taken".to_string()))
            }
            Err(err) => {
                tracing::error!(error = %err, "signup failed");
                SignupApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }

    /// List customers in allocation order.
    #[oai(path = "/customers", method = "get")]
    async fn list_customers(&self, _auth: AdminKey) -> ListApiResponse {
        match control_plane().list().await {
            Ok(customers) => ListApiResponse::Ok(Json(customers)),
            Err(err) => {
                tracing::error!(error = %err, "list customers failed");
                ListApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }

    /// Delete a customer (disruption-free: drops the WG peer via wg set).
    #[oai(path = "/customers/:username", method = "delete")]
    async fn delete_customer(
        &self,
        _auth: AdminKey,
        Path(username): Path<String>,
    ) -> DeleteApiResponse {
        match control_plane().delete(&username).await {
            Ok(()) => DeleteApiResponse::NoContent,
            Err(ControlPlaneError::NotFound(_)) => {
                DeleteApiResponse::NotFound(Json("customer not found".to_string()))
            }
            Err(err) => {
                tracing::error!(error = %err, username = %username, "delete customer failed");
                DeleteApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }

    /// The edge's own WG public key. Open (no auth) — it is a public
    /// key, and a convenient debug check.
    #[oai(path = "/pubkey", method = "get")]
    async fn edge_pubkey(&self) -> PubkeyApiResponse {
        match control_plane().edge_public_key().await {
            Ok(pubkey) => PubkeyApiResponse::Ok(Json(PubkeyResponse { public_key: pubkey })),
            Err(err) => {
                tracing::error!(error = %err, "edge pubkey failed");
                PubkeyApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }
}

/// Build the control-plane HTTP app: the OpenAPI service (the control
/// plane API merged with the health endpoints `/healthz` `/readyz`
/// `/status`), its bundled swagger UI at `/docs`, and the spec at
/// `/openapi.json`. The edge serves this one handler on its API port —
/// health and API checks come from the same listener. Stateless —
/// handlers read the process globals (the status func reads the
/// forwarder's live state lazily, per request).
pub fn app() -> Route {
    let status_func: StatusFunc = Arc::new(move || {
        serde_json::to_value(forwarder().stats()).unwrap_or(serde_json::Value::Null)
    });
    let service = OpenApiService::new(
        (ControlPlaneApi, HealthApi::new(status_func)),
        "cococoir edge",
        "0.1.0",
    );
    let ui = service.swagger_ui();
    let spec = service.spec_endpoint();
    Route::new()
        .nest("/", service)
        .nest("/docs", ui)
        .nest("/openapi.json", spec)
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
        // Process-lifetime test doubles: leaked so the control plane's
        // `&'static dyn` fields can borrow them; the test keeps the
        // reference to inspect recorded calls.
        let wg: &'static crate::controlplane::wg::MockWgClient =
            Box::leak(Box::new(crate::controlplane::wg::MockWgClient::new()));
        let dns: &'static crate::controlplane::dns::MockDnsApiClient =
            Box::leak(Box::new(crate::controlplane::dns::MockDnsApiClient::new()));
        let cp_owned =
            ControlPlane::with_deps(&url, subnet, wg_subnet, "interdim.net", wg, dns).unwrap();
        let forwarder_owned = Forwarder::new_live(Config::default()).unwrap();

        // Pre-seed the process globals (the test seam: set() bypasses
        // get_or_try_init, so no Redis hydration and a mock WG client).
        // set() errors (with the prior value) if the cell is already
        // full — a loud tripwire against two tests sharing a singleton.
        assert!(
            CONTROL_PLANE.set(cp_owned).is_ok(),
            "control plane set once"
        );
        assert!(FORWARDER.set(forwarder_owned).is_ok(), "forwarder set once");

        let cp = control_plane();
        let forwarder = forwarder();

        // Boot step: install the edge's identity into wg0 once. The
        // test's set() seam bypasses init_globals, so do the boot
        // install explicitly to mirror production.
        cp.install_edge_identity()
            .await
            .expect("install edge identity");

        let first_pub = generate_wg_keypair().0;
        let second_pub = generate_wg_keypair().0;
        let SignupOutcome::Created(first) =
            cp.signup("alice", &first_pub).await.expect("first signup")
        else {
            panic!("first signup created");
        };
        let SignupOutcome::Created(second) =
            cp.signup("bob", &second_pub).await.expect("second signup")
        else {
            panic!("second signup created");
        };
        assert_ne!(first.customer.ipv6, second.customer.ipv6);
        assert_eq!(first.customer.ipv6, "2a01:4f8:c17:1::2");
        assert_eq!(first.customer.wg_ip, "10.10.0.2");
        assert_eq!(second.customer.ipv6, "2a01:4f8:c17:1::3");
        assert_eq!(second.customer.wg_ip, "10.10.0.3");
        // Username is the id: DNS records were provisioned for both.
        assert_eq!(first.customer.username, "alice");
        assert_eq!(first.customer.hostname, "alice.interdim.net");
        assert_eq!(dns.upserts.lock().unwrap().len(), 4); // 2 customers × 2 records

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

        // The forwarder bound 4 live listeners (2 customers × 2 ports); the
        // WG client added both peers to the kernel interface.
        assert_eq!(forwarder.stats().forwards.len(), 4);
        assert!(forwarder.stats().forwards.iter().all(|s| s.bound));
        assert_eq!(wg.added.lock().unwrap().len(), 2);

        let customers = cp.list().await.expect("list");
        assert_eq!(customers.len(), 2);

        // Idempotent re-signup: same username + same key returns the
        // existing route (no new /128, no new DNS, no new forwarder
        // bind) and re-ensures the WG peer.
        let dns_before = dns.upserts.lock().unwrap().len();
        let forwards_before = forwarder.stats().forwards.len();
        let SignupOutcome::Existing(first_again) =
            cp.signup("alice", &first_pub).await.expect("idempotent re-signup")
        else {
            panic!("same-key re-signup is Existing");
        };
        assert_eq!(first_again.customer.ipv6, first.customer.ipv6, "same route");
        assert_eq!(first_again.customer.wg_ip, first.customer.wg_ip, "same route");
        assert_eq!(first_again.customer.wg_public_key, first_pub);
        assert_eq!(dns.upserts.lock().unwrap().len(), dns_before, "no new DNS");
        assert_eq!(
            forwarder.stats().forwards.len(),
            forwards_before,
            "no new forwarder bind"
        );
        assert_eq!(wg.added.lock().unwrap().len(), 3, "peer re-ensured");

        // Rotation: same username + a DIFFERENT key removes the old peer,
        // adds the new key on the SAME /128 + wg_ip, and persists it.
        let new_pub = generate_wg_keypair().0;
        let SignupOutcome::Existing(rotated) =
            cp.signup("alice", &new_pub).await.expect("rotate")
        else {
            panic!("rotation is Existing");
        };
        assert_eq!(rotated.customer.ipv6, first.customer.ipv6, "rotation keeps /128");
        assert_eq!(rotated.customer.wg_ip, first.customer.wg_ip, "rotation keeps wg_ip");
        assert_eq!(rotated.customer.wg_public_key, new_pub, "stored pubkey updated");
        assert_eq!(dns.upserts.lock().unwrap().len(), dns_before, "rotation no new DNS");
        assert!(
            wg.removed.lock().unwrap().contains(&first_pub),
            "old peer removed on rotation"
        );
        assert_eq!(wg.added.lock().unwrap().len(), 4, "new peer added on rotation");

        // A fresh signup still gets host 4: the idempotent re-signup and
        // rotation burned no /128.
        let third_pub = generate_wg_keypair().0;
        let SignupOutcome::Created(third) =
            cp.signup("carol", &third_pub).await.expect("third signup")
        else {
            panic!("carol created");
        };
        assert_eq!(third.customer.ipv6, "2a01:4f8:c17:1::4", "no wasted allocation");

        // The rotated key is what persisted: a subsequent signup with it
        // is an Existing no-op.
        let SignupOutcome::Existing(alice_now) =
            cp.signup("alice", &new_pub).await.expect("alice current key")
        else {
            panic!("alice current key is Existing");
        };
        assert_eq!(alice_now.customer.wg_public_key, new_pub);

        let customers = cp.list().await.expect("list with carol");
        assert_eq!(customers.len(), 3);

        cp.delete(&first.customer.username)
            .await
            .expect("delete first");
        // Rotation already removed alice's first key, so the delete
        // removes the rotated key too (2 removals total for alice).
        assert_eq!(forwarder.stats().forwards.len(), 4);
        assert_eq!(wg.removed.lock().unwrap().len(), 2);
        // Deleting removed the customer's DNS records (2 per customer).
        assert_eq!(dns.removes.lock().unwrap().len(), 2);

        let customers = cp.list().await.expect("list after delete");
        assert_eq!(customers.len(), 2);
        assert_eq!(customers[0].username, second.customer.username);

        cp.delete(&second.customer.username)
            .await
            .expect("delete second");
        assert!(matches!(
            cp.delete(&second.customer.username).await,
            Err(ControlPlaneError::NotFound(_))
        ));
        assert_eq!(forwarder.stats().forwards.len(), 2);
    }

    // ── HTTP API endpoint tests ──────────────────────────────────
    //
    // The auth gate and the OpenAPI spec are testable without Redis or
    // the process globals: auth fails during request extraction (before
    // the handler body runs), and the spec is derived from the code. So
    // these run against the real `app()` in any environment. The
    // /pubkey *handler* needs the control-plane global + a live store
    // (covered by `redis_store_round_trip`), so here we assert only the
    // spec-level fact that /pubkey is unguarded.

    use poem::http::StatusCode;
    use poem::test::TestClient;

    /// POST a signup without a bearer header → 401 (auth fails at
    /// extraction, before the handler reads any global).
    #[tokio::test]
    async fn signup_requires_auth() {
        let resp = TestClient::new(app())
            .post("/signup")
            .body_json(&serde_json::json!({ "username": "carol" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn list_customers_requires_auth() {
        let resp = TestClient::new(app()).get("/customers").send().await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn delete_customer_requires_auth() {
        let resp = TestClient::new(app())
            .delete("/customers/carol")
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    /// A *wrong* bearer token also fails (the gate is real, not just
    /// "a header present"). The checker SHA-256s + constant-time
    /// compares, so any non-matching token → 401. This exercises the
    /// real checker path against the real `SECRETS`... but `SECRETS` is
    /// a boot-only LazyLock, so in a test environment (no edge.env) it
    /// panics rather than resolving. We therefore assert the extraction
    /// rejects a structurally-invalid header (no scheme) here, and lean
    /// on `verify_token` unit tests for the crypto. Documented: the
    /// end-to-end "right key → 200, wrong key → 401" is proven by the
    /// L2 live test once the box holds edge.env.
    #[tokio::test]
    async fn signup_rejects_missing_scheme() {
        let resp = TestClient::new(app())
            .post("/signup")
            .body_json(&serde_json::json!({ "username": "carol" }))
            .header("Authorization", "carol")
            .send()
            .await;
        // No `Bearer` scheme → not a valid bearer token → 401, without
        // consulting the admin hash.
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    /// The OpenAPI spec is derived from the code: every protected
    /// operation must carry the bearer security requirement, and
    /// /pubkey must be unguarded (its operation declares no security).
    /// This is the tripwire that keeps the auth gate wired — a future
    /// edit that drops `_auth: AdminKey` from a handler silently opens
    /// that operation, and this test catches it.
    #[tokio::test]
    async fn spec_gates_protected_ops_and_leaves_pubkey_open() {
        let resp = TestClient::new(app()).get("/openapi.json").send().await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        let spec: serde_json::Value = serde_json::from_str(&body).unwrap();
        let paths = spec.get("paths").expect("paths present");

        // The bearer scheme is declared globally.
        let schemes = spec
            .get("components")
            .and_then(|c| c.get("securitySchemes"))
            .expect("securitySchemes present");
        assert!(
            schemes.get("AdminKey").is_some(),
            "spec declares the AdminKey security scheme"
        );

        // signup/list/delete require the scheme.
        for (path, methods) in [
            ("/signup", &["post"][..]),
            ("/customers", &["get"][..]),
            ("/customers/{username}", &["delete"][..]),
        ] {
            let method = methods[0];
            let op = paths
                .get(path)
                .unwrap_or_else(|| panic!("{path} in spec"))
                .get(method)
                .unwrap_or_else(|| panic!("{method} op in {path}"));
            assert!(
                op.get("security").is_some(),
                "{path} {method} declares a security requirement"
            );
        }

        // /pubkey is unguarded (no security requirement).
        let pubkey = paths
            .get("/pubkey")
            .expect("/pubkey in spec")
            .get("get")
            .expect("get op in /pubkey");
        assert!(
            pubkey.get("security").is_none(),
            "/pubkey declares NO security requirement"
        );
    }

    /// The swagger UI is served at /docs (mirroring health.rs).
    #[tokio::test]
    async fn swagger_ui_served_at_docs() {
        let resp = TestClient::new(app()).get("/docs").send().await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("swagger"), "swagger UI served at /docs");
    }

    /// The edge serves health from the same handler as the API: /healthz
    /// is reachable on app() (no separate health listener). /healthz
    /// always returns ok\n without touching the status func, so it works
    /// even when the process globals aren't initialized.
    #[tokio::test]
    async fn health_merged_into_api_handler() {
        let resp = TestClient::new(app()).get("/healthz").send().await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert_eq!(body, "ok\n");
    }
}
