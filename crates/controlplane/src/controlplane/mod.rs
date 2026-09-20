// SPDX-License-Identifier: AGPL-3.0-or-later
//! Control plane — the remote-access provisioning service.
//!
//! ADR-025: this is a *separate minimal service* from the client
//! dashboard. The dashboard manages household users on one server
//! (sqlite); this service manages *machines* on the edge (Redis) —
//! each owned by an account (ADR-032), or owner-less when the operator
//! provisions directly.
//!
//! HTTP surface — one binary, three namespaces:
//!   - **The API at `/api/`** (ONE swagger doc at `/api/docs`, spec at
//!     `/api/openapi.json`, server base `/api`):
//!     - `POST /api/wireguard/new` — allocate the next `/128` from the
//!       box's routed subnet, store the machine in Redis, add the
//!       machine's WG peer + live forwards, and return the route + the
//!       edge's public key. The machine's box dials out to the edge
//!       with that key. The client supplies its own WG public key
//!       (ADR-025: the edge never holds a machine private key); the
//!       call is idempotent and rotates the peer key on an existing
//!       route. This is the OWNER-LESS operator path — the customer
//!       path is invite enrollment (T6).
//!     - `GET /api/wireguard` / `DELETE /api/wireguard/:name` —
//!       list / remove (disruption-free: the control plane drops the WG
//!       peer via `wg set`, no restart).
//!     - `GET /api/wireguard/pubkey` — the edge's own WG public key
//!       (shared identity from the store-held key, ADR-029). Machine
//!       configs pull this instead of baking a static key.
//!     - `POST /api/users/{register,login,verify,reset_password,reset_password/confirm}`
//!       — the account lifecycle (T2/T3/T4): email signup + magic-link
//!       verify, session login, password reset.
//!     - `GET /api/healthz` `/api/readyz` `/api/status` — the forwarder
//!       health endpoints, part of the same service (see [`app`] for why
//!       health is not a second service).
//!   - **The web UI at the root** (`/`, `/register`, `/login`, `/verify`,
//!     `/reset`, `/auth/*`) — server-rendered forms driving the same
//!     `ControlPlane` account methods as the `/api/users` endpoints.
//!
//! Storage is Redis. The state (machines, allocations, keys) is
//! recoverable — a lost allocation is rebuilt from the edge's WG
//! peers — so Redis's simplicity wins over a SQL store. Durability is
//! AOF + `appendfsync always` (configured in the NixOS module),
//! deliberately not assumed.
//!
//! The `/128` allocation uses an atomic Redis counter (`INCR` on a
//! Lua-free single key — INCR is atomic in Redis). Host 1 is the
//! edge's own primary `/128`; machines start at host 2.

pub mod account;
pub mod auth;
pub mod dns;
pub mod mail;
pub mod pairing;
pub mod secret;
pub mod web;
pub mod wg;
pub use account::{AccountError, AccountRecord, AccountStatus, ResetOutcome, ResendVerifyOutcome};
pub use auth::{verify_token, AdminKey};
pub use dns::{
    get_dns_api, machine_hostname, reconcile_pass, remove_machine, resolve_aaaa,
    resolve_aaaa_boxed, upsert_machine, DnsApiClient, DnsError, HetznerDns, MockDnsApiClient,
};
pub use pairing::{EnrollmentDelivery, InviteError, InviteRecord, InviteStatus, PollOutcome};
pub use secret::{admin_key_hash, root_domain};
pub use wg::{MockWgClient, RealWgClient, WgClient, WgError};

use std::net::Ipv6Addr;
use std::sync::Arc;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use fortress_core::health::{HealthApi, StatusFunc};
use poem::web::Data;
use poem::{Endpoint, EndpointExt, Request, Response, Route};
use poem_openapi::param::Path;
use poem_openapi::payload::Json;
use poem_openapi::{ApiResponse, Object, OpenApi, OpenApiService};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};

use fortress_core::forwarder::{Config, Forward, Forwarder, Proto};

/// Redis key namespace for the control plane.
const MACHINE_KEY: &str = "fortress:machine:";
/// Redis key holding the next free host index within the box subnet.
const ALLOC_COUNTER: &str = "fortress:alloc:next";
/// Redis key holding the list of machine names.
const MACHINE_INDEX: &str = "fortress:machines";

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

/// Byte-level addressing for [`Subnet`]: N octets, parseable from a
/// string, with the subnet's byte-aligned prefix range. `Ipv6Addr`
/// carries the routed subnet (/64..=/112), `Ipv4Addr` the WireGuard
/// tunnel net (/8..=/30).
pub trait AddrBytes:
    Copy + std::fmt::Display + std::str::FromStr<Err = std::net::AddrParseError>
{
    const LEN: usize;
    const MIN_PREFIX: u8;
    const MAX_PREFIX: u8;
    fn octets(self) -> Vec<u8>;
    fn from_octets(octets: &[u8]) -> Self;
}

impl AddrBytes for std::net::Ipv6Addr {
    const LEN: usize = 16;
    const MIN_PREFIX: u8 = 64;
    const MAX_PREFIX: u8 = 112;
    fn octets(self) -> Vec<u8> {
        std::net::Ipv6Addr::octets(&self).to_vec()
    }
    fn from_octets(octets: &[u8]) -> Self {
        let octets: [u8; 16] = octets.try_into().expect("IPv6 octets are 16 bytes");
        std::net::Ipv6Addr::from(octets)
    }
}

impl AddrBytes for std::net::Ipv4Addr {
    const LEN: usize = 4;
    const MIN_PREFIX: u8 = 8;
    const MAX_PREFIX: u8 = 30;
    fn octets(self) -> Vec<u8> {
        std::net::Ipv4Addr::octets(&self).to_vec()
    }
    fn from_octets(octets: &[u8]) -> Self {
        let octets: [u8; 4] = octets.try_into().expect("IPv4 octets are 4 bytes");
        std::net::Ipv4Addr::from(octets)
    }
}

/// A byte-aligned subnet whose host indices fill the trailing
/// `LEN*8 - prefix_len` bits. The edge's routed IPv6 subnet and the
/// WireGuard tunnel net are the same shape (a prefix + a host index),
/// so the byte math lives here once, not in two copies. Customers use
/// the [`Subnet64`] / [`WgSubnet`] aliases.
#[derive(Debug, Clone)]
pub struct Subnet<A: AddrBytes> {
    /// The prefix bytes (everything up to the byte-aligned prefix
    /// boundary; the host bits are always zero).
    prefix: Vec<u8>,
    /// Prefix length in bits.
    prefix_len: u8,
    _addr: std::marker::PhantomData<A>,
}

impl<A: AddrBytes> Subnet<A> {
    /// Parse `addr/len`, rejecting unaligned or out-of-range prefix
    /// lengths and prefixes with host bits set.
    pub fn from_str(s: &str) -> Result<Self, String> {
        let (addr_str, len_str) = s
            .rsplit_once('/')
            .ok_or_else(|| format!("invalid subnet {s}: missing /len"))?;
        let prefix_len: u8 = len_str
            .parse()
            .map_err(|_| format!("invalid prefix length in {s}"))?;
        if prefix_len < A::MIN_PREFIX || prefix_len > A::MAX_PREFIX || prefix_len % 8 != 0 {
            return Err(format!(
                "{s}: prefix length must be byte-aligned and between /{} and /{} (was /{prefix_len})",
                A::MIN_PREFIX,
                A::MAX_PREFIX
            ));
        }
        let addr: A = addr_str
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
            _addr: std::marker::PhantomData,
        })
    }

    /// The address for a host index: host 1 is the edge's own primary
    /// address, host 2+ are customers. The index fills the trailing
    /// `LEN*8 - prefix_len` bits.
    fn host(&self, index: u64) -> A {
        let host_bits = A::LEN * 8 - self.prefix_len as usize;
        let max_host = ((1u128 << host_bits) - 1).min(u64::MAX as u128);
        if index as u128 > max_host {
            panic!("host index {index} exceeds /{} capacity", self.prefix_len);
        }
        // The index, right-aligned in a 16-byte buffer: the trailing
        // `host_bytes` are its low bits, byte-aligned by construction.
        let mut octets = [0u8; 16];
        octets[8..].copy_from_slice(&index.to_be_bytes());
        let host_bytes = host_bits / 8;
        let mut out = vec![0u8; A::LEN];
        out[..self.prefix.len()].copy_from_slice(&self.prefix);
        out[self.prefix.len()..].copy_from_slice(&octets[16 - host_bytes..]);
        A::from_octets(&out)
    }

    /// Human-readable address for `index`.
    pub fn host_string(&self, index: u64) -> String {
        self.host(index).to_string()
    }
}

/// The edge's routed IPv6 subnet, e.g. `2a01:4f8:c17:1::/64`.
///
/// The prefix length is NOT assumed to be `/64`: an operator who
/// manages one shared `/64` may hand each edge box a `/72` or `/96`
/// slice of it — any byte-aligned `/64..=/112` is accepted (finer and
/// a host index cannot fit safely).
pub type Subnet64 = Subnet<std::net::Ipv6Addr>;

/// The WireGuard tunnel network the edge and customers share, e.g.
/// `10.10.0.0/24` (byte-aligned `/8..=/30`). Host 1 is the edge
/// itself; customers get hosts 2+ — the same index as their `/128`.
pub type WgSubnet = Subnet<std::net::Ipv4Addr>;

#[derive(Debug, Serialize, Deserialize, Clone, Object)]
pub struct Machine {
    /// The machine's name — its identity AND its DNS label
    /// (`{name}.{domain}`). Globally unique across all accounts.
    pub name: String,
    /// The owning account's UUID, or `None` for an owner-less machine
    /// (the operator provisioning path). Machines are never
    /// reassigned — an orphaned box re-enrolls under a new account.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// The machine's DNS hostname, e.g. `main.proletariat.tech`.
    pub hostname: String,
    pub ipv6: String,
    /// The machine's WG tunnel address (dest for the edge's forwards).
    pub wg_ip: String,
    pub wg_public_key: String,
    /// SHA-256 of the machine's long-lived device token (hex). The token
    /// itself is delivered once during enrollment and never stored; the
    /// hash authorizes pubkey rotation on the same route (ADR-025's
    /// deferred gap, closed by T6).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_token_hash: Option<String>,
}

/// The enrollment response. The machine's private key never touches the
/// service — the client generates + persists it and sends only the
/// public key (ADR-025). The edge returns the route it allocated and
/// its own public key so the client can dial out.
#[derive(Debug, Serialize, Deserialize, Clone, Object)]
pub struct SignupResponse {
    pub machine: Machine,
    pub edge_public_key: String,
}

/// Whether an [`ControlPlane::allocate_machine`] call created a new
/// route or returned an existing one (idempotent no-op / key rotation).
#[derive(Debug)]
pub enum SignupOutcome {
    /// A fresh `/128` + WG tunnel was allocated.
    Created(SignupResponse),
    /// The name already existed; the response carries the existing
    /// route (unchanged `wg_ip`/`/128`), with the WG peer re-ensured or
    /// rotated to the supplied key.
    Existing(SignupResponse),
}

/// Error surface for control-plane operations.
#[derive(Debug, thiserror::Error)]
pub enum ControlPlaneError {
    #[error("redis error: {0}")]
    Redis(#[from] redis::RedisError),
    #[error("machine not found: {0}")]
    NotFound(String),
    #[error("allocation exhausted: {0}")]
    AllocExhausted(String),
    #[error("forwarder: {0}")]
    Forward(String),
    #[error("wg: {0}")]
    Wg(#[from] WgError),
    #[error("dns: {0}")]
    Dns(#[from] DnsError),
    #[error("invalid machine name: {0}")]
    InvalidName(String),
    #[error("invalid wireguard public key: {0}")]
    InvalidPubkey(String),
    #[error("machine name already taken: {0}")]
    Duplicate(String),
    #[error("account: {0}")]
    Account(#[from] AccountError),
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
    /// The process's one Redis connection, created lazily on first
    /// use and shared by every operation. The manager auto-reconnects
    /// after a Redis restart, so a lost connection self-heals instead
    /// of failing every request until a process restart. Cloning the
    /// handle is cheap (it multiplexes over one TCP connection).
    conn: tokio::sync::OnceCell<redis::aio::ConnectionManager>,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
    /// The domain customer hostnames live under. Injected (not read
    /// from the global [`secret::SECRETS`]) so tests can pass any
    /// domain without touching the boot-only secrets LazyLock.
    pub(crate) root_domain: &'static str,
    /// The shared `wg0` identity (ADR-029): one private key for both
    /// nodes, from the secret store. `&'static` for the same reason as
    /// `root_domain` — it lives in the process-lifetime `SECRETS`.
    edge_wg_private_key: &'static str,
    wg: &'static dyn WgClient,
    dns: &'static dyn DnsApiClient,
    /// The allocation counter's Redis key. Production: the shared
    /// [`ALLOC_COUNTER`]; tests: a per-instance key (parallel
    /// store-backed tests each own their allocation clock).
    alloc_key: &'static str,
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
            conn: tokio::sync::OnceCell::const_new(),
            subnet,
            wg_subnet,
            root_domain: secret::root_domain(),
            edge_wg_private_key: secret::wg_private_key(),
            wg: &*wg::REAL_WG_CLIENT,
            dns: get_dns_api(),
            alloc_key: ALLOC_COUNTER,
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
        wg_private_key: &'static str,
        wg: &'static dyn WgClient,
        dns: &'static dyn DnsApiClient,
    ) -> Result<Self, ControlPlaneError> {
        let client = redis::Client::open(redis_url)?;
        Ok(Self {
            client,
            conn: tokio::sync::OnceCell::const_new(),
            subnet,
            wg_subnet,
            root_domain,
            edge_wg_private_key: wg_private_key,
            wg,
            dns,
            alloc_key: ALLOC_COUNTER,
        })
    }

    /// A handle on the control plane's one Redis connection: created
    /// lazily on first use, then cloned per operation (multiplexed
    /// over one TCP connection, auto-reconnecting after a Redis
    /// restart). The old per-call `aio::Connection` opened a fresh
    /// TCP connection for every command.
    pub(crate) async fn conn(&self) -> Result<redis::aio::ConnectionManager, ControlPlaneError> {
        Ok(self
            .conn
            .get_or_try_init(|| async {
                let manager = redis::aio::ConnectionManager::new(self.client.clone()).await?;
                Ok::<_, ControlPlaneError>(manager)
            })
            .await?
            .clone())
    }

    /// The edge's own WireGuard public key, derived from the store-held
    /// private key. Pure getter — does not touch the kernel — so it is
    /// safe to call per-signup and from `GET /pubkey`. The edge's
    /// identity is stable across restarts (and across a rebuild) because
    /// it reads the same `WG_PRIVATE_KEY` from the store.
    pub fn edge_public_key(&self) -> Result<String, ControlPlaneError> {
        let private_key = self.edge_wg_private_key;
        let priv_bytes: [u8; 32] = B64
            .decode(private_key)
            .expect("store-held edge key is base64")
            .try_into()
            .map_err(|_| {
                ControlPlaneError::Wg(WgError::Io(std::io::Error::other(
                    "edge private key is not 32 bytes",
                )))
            })?;
        let secret = StaticSecret::from(priv_bytes);
        Ok(B64.encode(PublicKey::from(&secret).as_bytes()))
    }

    /// Boot-time: install the shared edge identity's private key into
    /// the running `wg0` interface, so the edge answers customer
    /// handshakes and any throwaway key `wg-quick up` left there is
    /// replaced. Called once by [`init_globals`], not per-signup.
    pub fn install_edge_identity(&self) -> Result<(), ControlPlaneError> {
        self.wg
            .set_private_key(self.edge_wg_private_key)
            .map_err(ControlPlaneError::Wg)
    }

    /// Allocate the next `/128` + WG tunnel address, create a machine,
    /// add the edge's forwards for the machine's `:80` and `:443`, and
    /// provision the machine's DNS AAAA records — all live, without
    /// touching existing forwards. Returns the signup response. The
    /// ONE allocation core (DRY): the owner-less operator path
    /// (`/api/wireguard/new`) and the invite-approval path (T6) both
    /// call it.
    ///
    /// DNS runs LAST and is non-fatal: the machine is reachable at
    /// its `/128` regardless, and the background reconcile loop
    /// self-heals a failed record.
    pub async fn allocate_machine(
        &self,
        owner: Option<&str>,
        name: &str,
        public_key: &str,
    ) -> Result<SignupOutcome, ControlPlaneError> {
        validate_machine_name(name)?;
        validate_wg_pubkey(public_key)?;
        let forwarder = forwarder();
        let mut conn = self.conn().await?;
        let key = format!("{MACHINE_KEY}{name}");
        let existing: Option<String> = conn.get(&key).await?;
        let edge_public_key = self.edge_public_key()?;

        // Idempotent / rotate path: the route already exists.
        if let Some(json) = existing {
            let mut machine: Machine = serde_json::from_str(&json).map_err(|err| {
                ControlPlaneError::Redis(redis::RedisError::from((
                    redis::ErrorKind::ResponseError,
                    "corrupt machine record",
                    format!("{json}: {err}"),
                )))
            })?;
            if machine.wg_public_key == public_key {
                // Same key: idempotent no-op. Re-ensure the peer (kernel
                // add_peer is idempotent); the `/128`+`wg_ip` are kept.
                if let Err(err) = self.wg.add_peer(&machine.wg_ip, public_key) {
                    tracing::error!(name = %name, err = %err, "allocate idempotent: wg re-add failed");
                }
            } else {
                // Different key: rotate. Remove the old peer first — two
                // peers sharing the `/32` allowed-ips would be ambiguous —
                // then add the new key on the SAME route (the forwarder
                // dest `wg_ip` is unchanged). Persist the new pubkey.
                if let Err(err) = self.wg.remove_peer(&machine.wg_public_key) {
                    tracing::error!(name = %name, err = %err, "allocate rotate: wg peer removal failed");
                }
                self.wg.add_peer(&machine.wg_ip, public_key)?;
                machine.wg_public_key = public_key.to_string();
                let updated = serde_json::to_string(&machine).expect("machine serializes");
                conn.set::<_, _, ()>(&key, updated).await?;
            }
            return Ok(SignupOutcome::Existing(SignupResponse {
                machine,
                edge_public_key,
            }));
        }

        // Fresh allocation. Existence is checked BEFORE allocating, so a
        // repeat call never burns a `/128` (the old INCR-before-check
        // order wasted an index even on the Duplicate error).
        let _: () = conn.set_nx(self.alloc_key, 1).await?;
        // INCR is atomic: no two enrollments can get the same host index.
        let index: i64 = conn.incr(self.alloc_key, 1).await?;
        if index < 2 {
            return Err(ControlPlaneError::AllocExhausted(
                "allocation counter below host 2".to_string(),
            ));
        }
        let ipv6 = self.subnet.host_string(index as u64);
        let wg_ip = self.wg_subnet.host_string(index as u64);

        let hostname = machine_hostname(name, self.root_domain);
        let machine = Machine {
            name: name.to_string(),
            owner: owner.map(str::to_string),
            hostname: hostname.clone(),
            ipv6: ipv6.clone(),
            wg_ip: wg_ip.clone(),
            wg_public_key: public_key.to_string(),
            device_token_hash: None,
        };

        let json = serde_json::to_string(&machine).expect("machine serializes");
        // Uniqueness is structural: the name IS the Redis key, so a
        // concurrent enrollment for the same name collides here.
        let set: bool = conn.set_nx(&key, json).await?;
        if !set {
            // The race loser gives its freshly-allocated index back, so
            // no /128 is burned even under concurrency.
            let _: i64 = conn.decr(self.alloc_key, 1).await?;
            return Err(ControlPlaneError::Duplicate(name.to_string()));
        }
        let _: i64 = conn.rpush(MACHINE_INDEX, name).await?;

        // Live wiring: WG peer + forwarder listeners. The store entry is
        // committed before wiring, so a crash mid-wiring leaves a record
        // that rehydrate wires up on next boot. A *wiring* failure, by
        // contrast, rolls the store entry back: the name and /128
        // must not stay burned when the peer/forward could not be
        // created.
        if let Err(err) = self.wg.add_peer(&wg_ip, public_key) {
            self.rollback_allocation(forwarder, name, &machine).await;
            return Err(ControlPlaneError::Wg(err));
        }
        for port in [80u16, 443] {
            let fwd = Forward {
                listen_addr: format!("[{ipv6}]:{port}"),
                proto: Proto::Tcp,
                dest_addr: format!("{wg_ip}:{port}"),
            };
            if let Err(err) = forwarder.add_forward(&fwd).await {
                self.rollback_allocation(forwarder, name, &machine).await;
                let addr = &fwd.listen_addr;
                return Err(ControlPlaneError::Forward(format!(
                    "add forward {addr}: {err}"
                )));
            }
        }

        // DNS last, non-fatal: the reconcile loop self-heals failures.
        if let Err(err) = upsert_machine(
            self.dns,
            name,
            ipv6.parse().expect("allocated /128 parses"),
            self.root_domain,
        )
        .await
        {
            tracing::error!(name = %name, err = %err, "allocate: dns upsert failed (machine reachable at /128; reconcile will self-heal)");
        }

        Ok(SignupOutcome::Created(SignupResponse {
            machine,
            edge_public_key,
        }))
    }

    /// Persist (overwrite) a machine record by name. Used by the
    /// enrollment flow to attach the device-token hash after allocation.
    pub(crate) async fn store_machine(&self, machine: &Machine) -> Result<(), ControlPlaneError> {
        let mut conn = self.conn().await?;
        let json = serde_json::to_string(machine).expect("machine serializes");
        let _: () = conn
            .set(format!("{MACHINE_KEY}{}", machine.name), json)
            .await?;
        Ok(())
    }

    /// List machines in allocation order.
    pub async fn list(&self) -> Result<Vec<Machine>, ControlPlaneError> {
        let mut conn = self.conn().await?;
        let names: Vec<String> = conn.lrange(MACHINE_INDEX, 0, -1).await?;
        let mut machines = Vec::new();
        for name in names {
            let json: Option<String> = conn.get(format!("{MACHINE_KEY}{name}")).await?;
            if let Some(json) = json {
                let machine = serde_json::from_str(&json).map_err(|err| {
                    ControlPlaneError::Redis(redis::RedisError::from((
                        redis::ErrorKind::ResponseError,
                        "corrupt machine record",
                        format!("{json}: {err}"),
                    )))
                })?;
                machines.push(machine);
            }
        }
        Ok(machines)
    }

    /// Boot-time reconciliation (obligatory, not optional): rebuild
    /// the routing table + live forwards from the durable store. Runs
    /// before the edge accepts traffic, so a crash never leaves a
    /// machine registered in Redis but not forwarded.
    pub async fn rehydrate(&self, forwarder: &Forwarder) -> Result<usize, ControlPlaneError> {
        let machines = self.list().await?;
        let mut count = 0usize;
        for machine in &machines {
            // Parse as a validity gate: a corrupt /128 is skipped loudly,
            // never panicked on.
            if machine.ipv6.parse::<Ipv6Addr>().is_err() {
                tracing::error!(name = %machine.name, ipv6 = %machine.ipv6, "skipping corrupt machine");
                continue;
            }
            if let Err(err) = self.wg.add_peer(&machine.wg_ip, &machine.wg_public_key) {
                tracing::error!(name = %machine.name, wg_ip = %machine.wg_ip, err = %err, "rehydrate wg add failed");
            }
            for port in [80u16, 443] {
                let fwd = Forward {
                    listen_addr: format!("[{}]:{port}", machine.ipv6),
                    proto: Proto::Tcp,
                    dest_addr: format!("{}:{port}", machine.wg_ip),
                };
                if let Err(err) = forwarder.add_forward(&fwd).await {
                    tracing::error!(name = %machine.name, addr = %fwd.listen_addr, err = %err, "rehydrate bind failed");
                }
            }
            count += 1;
        }
        tracing::info!(machines = count, forwards = %forwarder.stats().forwards.len(), "live forwards rehydrated");
        Ok(count)
    }

    /// Delete a machine: unwire the WG peer + live forwards + DNS AAAA
    /// records, then remove the store entry (freeing the name back to
    /// the pool). Unwiring comes FIRST and is best-effort: the store
    /// entry is the durable source `rehydrate` reads, so it must be the
    /// last thing removed — if unwiring fails mid-way and the entry were
    /// already gone, the orphaned listeners would be unfixable on any
    /// future boot.
    pub async fn delete(&self, name: &str) -> Result<(), ControlPlaneError> {
        let forwarder = forwarder();
        let mut conn = self.conn().await?;
        let key = format!("{MACHINE_KEY}{name}");
        let json: Option<String> = conn.get(&key).await?;
        let Some(json) = json else {
            return Err(ControlPlaneError::NotFound(name.to_string()));
        };
        let machine: Machine = match serde_json::from_str(&json) {
            Ok(machine) => machine,
            Err(err) => {
                // Corrupt record: we cannot unwire it (its data is gone),
                // but the store entry must still drop so the name is
                // freed and rehydrate stops resurrecting it.
                tracing::error!(name = %name, err = %err, "delete: corrupt machine record; removing entry without unwiring");
                let _: i64 = conn.del(&key).await?;
                let _: i64 = conn.lrem(MACHINE_INDEX, 1, name).await?;
                return Ok(());
            }
        };

        // Unwire first, best-effort: a WG or DNS failure is logged, never
        // fatal, so the store entry is always removed.
        if let Err(err) = self.wg.remove_peer(&machine.wg_public_key) {
            tracing::error!(name = %name, err = %err, "delete: wg peer removal failed; stale peer may remain");
        }
        for port in [80u16, 443] {
            let fwd = Forward {
                listen_addr: format!("[{}]:{port}", machine.ipv6),
                proto: Proto::Tcp,
                dest_addr: format!("{}:{port}", machine.wg_ip),
            };
            forwarder.remove_forward(&fwd);
        }
        // DNS removal is best-effort: the machine is already gone from
        // the tunnel; a provider outage leaves a stale record that the
        // reconcile loop cannot prune (it only re-applies for existing
        // machines). Logged loudly, never silent.
        if let Err(err) = remove_machine(self.dns, name, self.root_domain).await {
            tracing::error!(name = %name, err = %err, "delete: dns remove failed; stale records may remain");
        }

        // Store last.
        let _: i64 = conn.del(&key).await?;
        let _: i64 = conn.lrem(MACHINE_INDEX, 1, name).await?;
        Ok(())
    }

    /// Best-effort rollback of a failed [`ControlPlane::allocate_machine`]:
    /// drop the store entry and unwire whatever was partially created.
    /// Runs after the record is committed but a live-wiring step failed,
    /// so the name + /128 are freed and `rehydrate` cannot resurrect a
    /// zombie (whose private key would be unrecoverable). Never fails the
    /// original error; logs any cleanup failure.
    async fn rollback_allocation(&self, forwarder: &Forwarder, name: &str, machine: &Machine) {
        let Ok(mut conn) = self.conn().await else {
            tracing::error!(name = %name, "allocate rollback: redis unreachable; zombie record may persist");
            return;
        };
        let _: i64 = match conn.del(format!("{MACHINE_KEY}{name}")).await {
            Ok(n) => n,
            Err(err) => {
                tracing::error!(name = %name, err = %err, "allocate rollback: store delete failed; zombie record may persist");
                return;
            }
        };
        let _: i64 = match conn.lrem(MACHINE_INDEX, 1, name).await {
            Ok(n) => n,
            Err(err) => {
                tracing::error!(name = %name, err = %err, "allocate rollback: index removal failed");
                return;
            }
        };
        if let Err(err) = self.wg.remove_peer(&machine.wg_public_key) {
            tracing::error!(name = %name, err = %err, "allocate rollback: wg peer removal failed");
        }
        for port in [80u16, 443] {
            forwarder.remove_forward(&Forward {
                listen_addr: format!("[{}]:{port}", machine.ipv6),
                proto: Proto::Tcp,
                dest_addr: format!("{}:{port}", machine.wg_ip),
            });
        }
    }

    /// One DNS reconcile pass: verify each machine's two AAAA records
    /// against real resolution (1.1.1.1) and re-apply mismatches.
    pub async fn reconcile_dns_once(&self) -> Result<usize, ControlPlaneError> {
        let machines = self.list().await?;
        let pairs: Vec<(String, Ipv6Addr)> = machines
            .into_iter()
            .filter_map(|m| m.ipv6.parse().ok().map(|ip: Ipv6Addr| (m.name, ip)))
            .collect();
        Ok(reconcile_pass(self.dns, &pairs, resolve_aaaa_boxed, self.root_domain).await)
    }
}

/// Generate a WireGuard keypair. WireGuard keys are Curve25519
/// (x25519); the private key is a random 32-byte scalar, the public
/// key is the x25519 base-point multiplication. Delegates to the shared
/// `fortress_core::wg` helper so the crypto lives in one place (the
/// client uses the same code).
pub fn generate_wg_keypair() -> (String, String) {
    fortress_core::wg::generate_keypair()
}

/// Validate a machine name as a DNS label, because the name becomes the
/// first label of every hostname the machine serves
/// (`{name}.{DOMAIN}` + `{service}.{name}.{DOMAIN}`). Lowercase
/// alphanumeric + hyphen, not starting/ending with hyphen, no `--`
/// (punycode reserve), and at least **6 characters** — the anti-squat
/// floor (ADR-032): drains the vanity value of `main`/`home`/`box`.
/// Reserved names (the zone apex's own infrastructure + common service
/// labels) are refused — first-come-first-served on a shared zone is a
/// squatting/typo vector.
pub fn validate_machine_name(name: &str) -> Result<(), ControlPlaneError> {
    const RESERVED: &[&str] = &[
        "www",
        "mail",
        "mx",
        "smtp",
        "imap",
        "webmail",
        "autodiscover",
        "ns",
        "ns1",
        "ns2",
        "ftp",
        "api",
        "admin",
        "edge",
        "fortress",
        "redis",
        "vault",
        "status",
        "docs",
        "vpn",
        "jellyfin",
        "cryptpad",
        "radarr",
        "sonarr",
        "seerr",
        "media",
        "caddy",
        "dex",
    ];
    let ok = name.len() >= 6
        && name.len() <= 63
        && !name.starts_with('-')
        && !name.ends_with('-')
        && !name.contains("--")
        && !RESERVED.contains(&name)
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if ok {
        Ok(())
    } else {
        Err(ControlPlaneError::InvalidName(name.to_string()))
    }
}

/// Validate a client-supplied WireGuard public key: a well-formed WG
/// public key is 32 bytes of base64. The kernel re-validates on `wg
/// set`; this is a cheap structural gate so a bad key fails before any
/// allocation or wiring.
pub fn validate_wg_pubkey(public_key: &str) -> Result<(), ControlPlaneError> {
    let ok = B64
        .decode(public_key)
        .map(|b| b.len() == 32)
        .unwrap_or(false);
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

/// The dummy/dev boot domain and edge WG key, injected instead of the
/// boot secrets (`--dummy`). The WG key is a valid x25519 base64 string
/// so the pubkey derivation (`ControlPlane::edge_public_key`) works if a
/// dev box is ever used for a real signup round trip.
pub const DUMMY_ROOT_DOMAIN: &str = "dev.local";
pub const DUMMY_EDGE_WG_PRIV: &str = "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=";

/// Initialize the process globals, hydrating the live forwarder from
/// Redis before it becomes visible. Order matters: forwarder → control
/// plane → rehydrate (rehydrate needs the control plane's Redis
/// connection and the forwarder to bind into). Each `get_or_try_init`
/// returns `Err` on unreachable Redis rather than panicking, so a boot
/// or test that can't reach Redis fails cleanly. Tests bypass this
/// entirely by `set()`-ing their own instances.
///
/// `dummy` selects the dev/dummy boot path (the `--dummy` flag, which
/// only compiles into debug builds): no boot secrets, no wg0, no DNS
/// provider, console mailer — but the same forwarder, Redis store, and
/// HTTP wiring as prod.
pub async fn init_globals(
    redis_url: &str,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
    ipv6_iface: Option<String>,
    dummy: bool,
) -> Result<(), ControlPlaneError> {
    if dummy {
        init_globals_dummy(redis_url, subnet, wg_subnet, ipv6_iface).await
    } else {
        init_globals_real(redis_url, subnet, wg_subnet, ipv6_iface).await
    }
}

/// The production boot path: resolve the boot secrets (DNS zone, admin
/// key, SMTP) — a missing secret fails boot, never a first-signup
/// surprise — then the shared forwarder/store tail.
async fn init_globals_real(
    redis_url: &str,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
    ipv6_iface: Option<String>,
) -> Result<(), ControlPlaneError> {
    // DNS config is process config: a missing zone/token is a boot
    // error, never a first-signup surprise. Forcing the `LazyLock`
    // resolves the secrets + builds the DNS client now.
    let _ = secret::root_domain();
    let _ = get_dns_api();
    // The mailer is process config too: a configured-but-broken SMTP
    // relay fails boot, never a silent fallback to the console.
    mail::init_mailer().expect("mailer init: configured SMTP relay must build");
    init_forwarder_and_store(
        redis_url,
        subnet,
        wg_subnet,
        ipv6_iface,
        |url, sub, wgsub| {
            let cp = ControlPlane::new(url, sub, wgsub)?;
            cp.install_edge_identity()?;
            Ok(cp)
        },
    )
    .await
}

/// The dev/dummy boot path: no boot secrets (absent on a dev box), no
/// wg0, no DNS provider, console mailer — the control plane runs against
/// the injected mock WG + DNS clients. Everything after this — the
/// forwarder, the Redis store, the [`app`] HTTP wiring — is the same
/// code as prod, which is the point: the dev box exercises it.
async fn init_globals_dummy(
    redis_url: &str,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
    ipv6_iface: Option<String>,
) -> Result<(), ControlPlaneError> {
    mail::init_console_mailer();
    init_forwarder_and_store(
        redis_url,
        subnet,
        wg_subnet,
        ipv6_iface,
        |url, sub, wgsub| {
            let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
            let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
            let cp = ControlPlane::with_deps(
                url,
                sub,
                wgsub,
                DUMMY_ROOT_DOMAIN,
                DUMMY_EDGE_WG_PRIV,
                wg,
                dns,
            )?;
            cp.install_edge_identity()?;
            Ok(cp)
        },
    )
    .await
}

/// Shared boot tail for both paths: init the forwarder, build the
/// control plane via `build_cp`, then rehydrate the live forwards from
/// the durable store. Keeping this shared is what guarantees the
/// dummy/dev edge and the production edge take identical paths through
/// the forwarder, store, and rehydrate code.
async fn init_forwarder_and_store(
    redis_url: &str,
    subnet: Subnet64,
    wg_subnet: WgSubnet,
    ipv6_iface: Option<String>,
    build_cp: impl FnOnce(&str, Subnet64, WgSubnet) -> Result<ControlPlane, ControlPlaneError>,
) -> Result<(), ControlPlaneError> {
    FORWARDER
        .get_or_try_init(|| async {
            Forwarder::new_live(Config {
                ipv6_iface,
                ..Config::default()
            })
            .map_err(|err| ControlPlaneError::Forward(format!("forwarder init: {err}")))
        })
        .await?;
    CONTROL_PLANE
        .get_or_try_init(|| async { build_cp(redis_url, subnet, wg_subnet) })
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
/// derived from the code ("compiles ⟹ spec-correct"). The whole API is
/// mounted under `/api/` — ONE service (users + wireguard merged), ONE
/// swagger doc at `/api/docs`, the spec at `/api/openapi.json` with the
/// server base `/api` — so the API namespace is entirely separate from
/// the web UI at the root. The wireguard handlers read the process
/// singletons directly (they only run with the globals set, i.e.
/// production). The users handlers read the injected [`AppState`]
/// (falling back to the process globals) so tests can run the full
/// account round trip without fighting the singletons. Every wireguard
/// operation except `/wireguard/pubkey` takes an [`AdminKey`] arg, so
/// the spec declares the bearer scheme and the Authorize button in
/// swagger works.
/// The injected dependencies shared by the web UI (root) and the users shared by the web UI (root) and the users
/// API handlers (`/api/users/*`). `ControlPlane` is deliberately not
/// `Clone` (it's a process-lifetime singleton), so the state carries
/// `&'static` references instead of the value. `None` only when the
/// globals aren't initialized — the handlers fail loudly (500) rather
/// than silently if such a route is ever hit.
#[derive(Clone, Copy)]
pub struct AppState {
    pub cp: Option<&'static ControlPlane>,
    pub mailer: Option<&'static dyn mail::Mailer>,
}

/// The API's control plane: the injected one, else the process global.
fn api_cp(state: &AppState) -> Option<&'static ControlPlane> {
    state.cp.or_else(|| CONTROL_PLANE.get())
}

/// The API's mailer: the injected one, else the process mailer.
fn api_mailer(state: &AppState) -> Option<&'static dyn mail::Mailer> {
    state.mailer.or_else(mail::mailer_opt)
}

// ── /api/users/* — shared bodies + error mapping ────────────────

/// A human-readable status message (the users endpoints respond with
/// these).
#[derive(Debug, Serialize, Deserialize, Object)]
pub struct MessageBody {
    pub message: String,
}

/// A session token, returned by `POST /api/users/login`.
#[derive(Debug, Serialize, Deserialize, Object)]
pub struct SessionToken {
    pub token: String,
}

/// Status + body for the `/api/users/*` endpoints.
#[derive(ApiResponse)]
enum UsersApiResponse {
    #[oai(status = "200")]
    Ok(Json<MessageBody>),
    #[oai(status = "201")]
    Created(Json<MessageBody>),
    #[oai(status = "200")]
    Session(Json<SessionToken>),
    #[oai(status = "400")]
    BadRequest(Json<String>),
    #[oai(status = "401")]
    Unauthorized(Json<String>),
    #[oai(status = "403")]
    Forbidden(Json<String>),
    #[oai(status = "404")]
    NotFound(Json<String>),
    #[oai(status = "409")]
    Conflict(Json<String>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Map an account error to its users-API response. Login failures stay
/// generic (no account enumeration), matching the web layer's
/// `account_error_message`.
fn users_api_error(err: AccountError) -> UsersApiResponse {
    use crate::controlplane::web::account_error_message;
    match err {
        AccountError::InvalidEmail(_) | AccountError::InvalidPassword(_) => {
            UsersApiResponse::BadRequest(Json(account_error_message(&err)))
        }
        AccountError::DuplicateEmail(_) => {
            UsersApiResponse::Conflict(Json(account_error_message(&err)))
        }
        AccountError::NotFound => UsersApiResponse::NotFound(Json("account not found".to_string())),
        AccountError::InvalidCredentials => {
            UsersApiResponse::Unauthorized(Json("invalid email or password".to_string()))
        }
        AccountError::NotVerified(_) => {
            UsersApiResponse::Forbidden(Json(
                "verify your email first — POST /api/users/resend_verification to resend the link"
                    .to_string(),
            ))
        }
        AccountError::InvalidToken => {
            UsersApiResponse::BadRequest(Json("invalid or expired token".to_string()))
        }
        AccountError::Corrupt(_) | AccountError::Redis(_) => {
            UsersApiResponse::Internal(Json("internal error".to_string()))
        }
        AccountError::Mail(_) => {
            UsersApiResponse::Internal(Json("we couldn't send that email right now".to_string()))
        }
    }
}

// ── /api/users/* — the account lifecycle ─────────────────────────

#[derive(Debug, Deserialize, Object)]
pub struct RegisterRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize, Object)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize, Object)]
pub struct VerifyRequest {
    pub token: String,
}

#[derive(Debug, Deserialize, Object)]
pub struct ResetPasswordRequest {
    pub email: String,
}

#[derive(Debug, Deserialize, Object)]
pub struct ResetPasswordConfirmRequest {
    pub token: String,
    pub password: String,
}

/// The account lifecycle API. Public — no bearer auth, the session token
/// IS the auth. Thin JSON wrappers over the `ControlPlane` account
/// methods (T2); the web UI forms at the root drive the same methods.
struct UsersApi;

#[OpenApi]
impl UsersApi {
    /// Create an account (pending) and email a single-use verification
    /// link. Same semantics as the web `/register` form.
    #[oai(path = "/users/register", method = "post")]
    async fn register(
        &self,
        Data(state): Data<&AppState>,
        Json(req): Json<RegisterRequest>,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        let Some(mailer) = api_mailer(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.account_signup(&req.email, &req.password, mailer).await {
            Ok(()) => UsersApiResponse::Created(Json(MessageBody {
                message: format!("a verification link was sent to {}", req.email),
            })),
            Err(err) => users_api_error(err),
        }
    }

    /// Log in with email + password. Returns the session token (the web
    /// UI sets the same token as an HttpOnly cookie instead).
    #[oai(path = "/users/login", method = "post")]
    async fn login(
        &self,
        Data(state): Data<&AppState>,
        Json(req): Json<LoginRequest>,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.account_login(&req.email, &req.password).await {
            Ok(token) => UsersApiResponse::Session(Json(SessionToken { token })),
            Err(err) => users_api_error(err),
        }
    }

    /// Confirm the email with the single-use magic-link token. The web
    /// UI renders the link's confirm form and consumes the token the
    /// same way.
    #[oai(path = "/users/verify", method = "post")]
    async fn verify(
        &self,
        Data(state): Data<&AppState>,
        Json(req): Json<VerifyRequest>,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.account_verify(&req.token).await {
            Ok(()) => UsersApiResponse::Ok(Json(MessageBody {
                message: "email verified".to_string(),
            })),
            Err(err) => users_api_error(err),
        }
    }

    /// Request a password-reset link. The outcome is explicit: a known
    /// email confirms the link is on its way, an unknown one says so —
    /// enumeration is already possible via signup's duplicate-email
    /// error, so a generic response protects nothing.
    #[oai(path = "/users/reset_password", method = "post")]
    async fn reset_password(
        &self,
        Data(state): Data<&AppState>,
        Json(req): Json<ResetPasswordRequest>,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        let Some(mailer) = api_mailer(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.request_password_reset(&req.email, mailer).await {
            Ok(ResetOutcome::Sent) => UsersApiResponse::Ok(Json(MessageBody {
                message: "a reset link is on its way — check your inbox".to_string(),
            })),
            Ok(ResetOutcome::UnknownEmail) => UsersApiResponse::Ok(Json(MessageBody {
                message: "no account with that email — sign up first".to_string(),
            })),
            Err(err) => users_api_error(err),
        }
    }

    /// Resend the verification link for a pending account. The outcome
    /// is explicit (see [`ResendVerifyOutcome`]): pending → link sent,
    /// active → already verified, unknown → no account.
    #[oai(path = "/users/resend_verification", method = "post")]
    async fn resend_verification(
        &self,
        Data(state): Data<&AppState>,
        Json(req): Json<ResetPasswordRequest>,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        let Some(mailer) = api_mailer(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.resend_verification(&req.email, mailer).await {
            Ok(ResendVerifyOutcome::Sent) => UsersApiResponse::Ok(Json(MessageBody {
                message: "a verification link is on its way — check your inbox".to_string(),
            })),
            Ok(ResendVerifyOutcome::AlreadyActive) => UsersApiResponse::Ok(Json(MessageBody {
                message: "that email is already verified — log in".to_string(),
            })),
            Ok(ResendVerifyOutcome::UnknownEmail) => UsersApiResponse::Ok(Json(MessageBody {
                message: "no account with that email — sign up first".to_string(),
            })),
            Err(err) => users_api_error(err),
        }
    }

    /// Apply a new password with the single-use reset token.
    #[oai(path = "/users/reset_password/confirm", method = "post")]
    async fn reset_password_confirm(
        &self,
        Data(state): Data<&AppState>,
        Json(req): Json<ResetPasswordConfirmRequest>,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.reset_password(&req.token, &req.password).await {
            Ok(()) => UsersApiResponse::Ok(Json(MessageBody {
                message: "password updated".to_string(),
            })),
            Err(err) => users_api_error(err),
        }
    }

    /// Delete the logged-in account: every machine unwired, every
    /// invite + session + the record dropped. The box's data is never
    /// touched. Session-auth (the cookie IS the auth).
    #[oai(path = "/account", method = "delete")]
    async fn delete_account(
        &self,
        Data(state): Data<&AppState>,
        req: &Request,
    ) -> UsersApiResponse {
        let Some(cp) = api_cp(state) else {
            return UsersApiResponse::Internal(Json("internal error".to_string()));
        };
        let Some(token) = crate::controlplane::web::read_cookie(req, web::SESSION_COOKIE) else {
            return UsersApiResponse::Unauthorized(Json("no session".to_string()));
        };
        let email = match cp.session_account(&token).await {
            Ok(Some(email)) => email,
            _ => return UsersApiResponse::Unauthorized(Json("no session".to_string())),
        };
        match cp.account_delete(&email).await {
            Ok(()) => UsersApiResponse::Ok(Json(MessageBody {
                message: "account deleted".to_string(),
            })),
            Err(AccountError::NotFound) => {
                UsersApiResponse::Unauthorized(Json("no session".to_string()))
            }
            Err(err) => {
                tracing::error!(error = %err, "account delete failed");
                UsersApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }
}

// ── /api/wireguard/* — machine routes + the edge's WG identity ─────

/// The owner-less operator request body: the machine name that becomes
/// the machine's DNS hostname, plus the machine's WireGuard public key
/// (the client generates + holds the private key; the edge stores only
/// the public key — ADR-025). Legacy field name `username` on the wire
/// is GONE — this is the T5 unification: one name concept, one wire.
#[derive(Debug, Deserialize, Object)]
pub struct SignupRequest {
    pub name: String,
    pub public_key: String,
}

/// `/api/wireguard/pubkey` response: the edge's own WG public key.
#[derive(Debug, Serialize, Deserialize, Object)]
pub struct PubkeyResponse {
    pub public_key: String,
}

/// Status + body for `POST /api/wireguard/new`.
#[derive(ApiResponse)]
enum SignupApiResponse {
    /// Machine route created.
    #[oai(status = "201")]
    Created(Json<SignupResponse>),
    /// Machine route already existed (idempotent no-op or key rotation).
    #[oai(status = "200")]
    Ok(Json<SignupResponse>),
    /// Invalid machine name or public key.
    #[oai(status = "400")]
    BadRequest(Json<String>),
    /// Machine name already taken (concurrent race).
    #[oai(status = "409")]
    Conflict(Json<String>),
    /// Internal error.
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Status + body for `GET /api/wireguard`.
#[derive(ApiResponse)]
enum ListApiResponse {
    #[oai(status = "200")]
    Ok(Json<Vec<Machine>>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Status + body for `DELETE /api/wireguard/:name`.
#[derive(ApiResponse)]
enum DeleteApiResponse {
    #[oai(status = "204")]
    NoContent,
    #[oai(status = "404")]
    NotFound(Json<String>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// Status + body for `GET /api/wireguard/pubkey`.
#[derive(ApiResponse)]
enum PubkeyApiResponse {
    #[oai(status = "200")]
    Ok(Json<PubkeyResponse>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

/// The wireguard API — machine routes + the edge's own WG identity. Unit
/// struct — reads the process globals.
struct WireguardApi;

#[OpenApi]
impl WireguardApi {
    /// Create a machine route (allocate a /128, forwards, DNS) or, if the
    /// name already exists, re-ensure / rotate the WG peer on the
    /// existing route. The client supplies its own WG public key; the
    /// edge never sees the private key. Owner-less (operator path).
    #[oai(path = "/wireguard/new", method = "post")]
    async fn signup(&self, _auth: AdminKey, Json(req): Json<SignupRequest>) -> SignupApiResponse {
        match control_plane()
            .allocate_machine(None, &req.name, &req.public_key)
            .await
        {
            Ok(SignupOutcome::Created(resp)) => SignupApiResponse::Created(Json(resp)),
            Ok(SignupOutcome::Existing(resp)) => SignupApiResponse::Ok(Json(resp)),
            Err(ControlPlaneError::InvalidName(name)) => {
                tracing::warn!(name = %name, "wireguard/new: invalid machine name");
                SignupApiResponse::BadRequest(Json(
                    "invalid machine name (≥6 chars: lowercase letters, digits, hyphens; not a reserved word)"
                        .to_string(),
                ))
            }
            Err(ControlPlaneError::InvalidPubkey(_)) => {
                tracing::warn!("wireguard/new: invalid wireguard public key");
                SignupApiResponse::BadRequest(Json("invalid wireguard public key".to_string()))
            }
            Err(ControlPlaneError::Duplicate(name)) => {
                tracing::warn!(name = %name, "wireguard/new: machine name taken");
                SignupApiResponse::Conflict(Json("machine name already taken".to_string()))
            }
            Err(err) => {
                tracing::error!(error = %err, "wireguard/new failed");
                SignupApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }

    /// List machine routes in allocation order.
    #[oai(path = "/wireguard", method = "get")]
    async fn list_machines(&self, _auth: AdminKey) -> ListApiResponse {
        match control_plane().list().await {
            Ok(machines) => ListApiResponse::Ok(Json(machines)),
            Err(err) => {
                tracing::error!(error = %err, "list machine routes failed");
                ListApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }

    /// Delete a machine route (disruption-free: drops the WG peer via wg
    /// set).
    #[oai(path = "/wireguard/:name", method = "delete")]
    async fn delete_machine(&self, _auth: AdminKey, Path(name): Path<String>) -> DeleteApiResponse {
        match control_plane().delete(&name).await {
            Ok(()) => DeleteApiResponse::NoContent,
            Err(ControlPlaneError::NotFound(_)) => {
                DeleteApiResponse::NotFound(Json("machine not found".to_string()))
            }
            Err(err) => {
                tracing::error!(error = %err, name = %name, "delete machine route failed");
                DeleteApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }

    /// The edge's own WG public key. Open (no auth) — it is a public
    /// key, and a convenient debug check.
    #[oai(path = "/wireguard/pubkey", method = "get")]
    async fn edge_pubkey(&self) -> PubkeyApiResponse {
        match control_plane().edge_public_key() {
            Ok(pubkey) => PubkeyApiResponse::Ok(Json(PubkeyResponse { public_key: pubkey })),
            Err(err) => {
                tracing::error!(error = %err, "edge pubkey failed");
                PubkeyApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }
}

/// Build the control-plane HTTP app: the API under `/api/` (the users +
/// wireguard + health operations merged into ONE OpenAPI service,
/// swagger UI at `/api/docs`, spec at `/api/openapi.json`, server base
/// `/api`) and the customer-facing web UI at the root (`/`, `/register`,
/// `/login`, `/verify`, …). The edge serves this one handler on its API
/// port. Stateless — handlers read the process globals lazily, per
/// request.
///
/// Health is part of the API service, not a separate one: two
/// poem-openapi services cannot coexist in one route tree (each
/// registers an internal `/*--poem-rest` catch-all that collides), so
/// `/healthz` `/readyz` `/status` live at `/api/*` with everything else
/// — one listener, one swagger doc.
pub fn app() -> impl Endpoint<Output = Response> {
    let status_func: StatusFunc = Arc::new(move || {
        serde_json::to_value(forwarder().stats()).unwrap_or(serde_json::Value::Null)
    });
    let cp = CONTROL_PLANE.get();
    let mailer = mail::mailer_opt();
    app_with(status_func, cp, mailer)
}

/// Like [`app`] but with injectable deps — used by the web + API tests,
/// which must not fight `redis_store_round_trip` over the process
/// singletons. The web + users-api handlers mount with `None` deps when
/// the process globals aren't initialized; they then fail loudly (500)
/// if hit, which only happens when a test touches such a route without
/// injecting deps.
pub fn app_with(
    status_func: StatusFunc,
    cp: Option<&'static ControlPlane>,
    mailer: Option<&'static dyn mail::Mailer>,
) -> impl Endpoint<Output = Response> {
    let service = OpenApiService::new(
        (
            UsersApi,
            WireguardApi,
            pairing::invites_api(),
            HealthApi::new(status_func),
        ),
        "fortress edge API",
        "0.1.0",
    )
    .server("/api");
    let ui = service.swagger_ui();
    let spec = service.spec_endpoint();
    Route::new()
        .nest("/api", service)
        .nest("/api/docs", ui)
        .nest("/api/openapi.json", spec)
        .nest("/", web::web_routes())
        .data(AppState { cp, mailer })
}

/// Seed the shared forwarder cell if a test is the first to need it.
/// `set()` errors (with the prior value) if another test already seeded
/// — harmless, since the content is identical (a default live
/// forwarder), so the race loser just reuses the winner's instance.
/// Lives at module level so every test module (mod tests, pairing
/// tests) can call it. The CONTROL_PLANE cell is NOT shared the same
/// way — tests that exercise the process-global seam assert `set()`
/// succeeded (loud tripwire against sharing that singleton).
#[allow(dead_code)]
pub(crate) fn set_forwarder_for_tests() {
    let _ = FORWARDER.set(Forwarder::new_live(Config::default()).unwrap());
}

#[cfg(test)]
impl ControlPlane {
    /// Point this instance's allocation counter at its own key, so
    /// parallel store-backed tests never race one allocation clock
    /// (INCR is atomic, but one test's counter cleanup must not reset
    /// another test's clock mid-flight).
    pub fn isolated_alloc(mut self, key: &'static str) -> Self {
        self.alloc_key = key;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test-only fixture for the shared `wg0` identity (ADR-029). A real
    /// WireGuard private key (base64, 32 bytes); the store holds the
    /// production one, tests inject this literal so they never force the
    /// boot-only `SECRETS` LazyLock.
    const TEST_EDGE_WG_PRIV: &str = "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=";

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
    #[cfg(feature = "redis-tests")]
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
        let cp_owned = ControlPlane::with_deps(
            &url,
            subnet,
            wg_subnet,
            "proletariat.tech",
            TEST_EDGE_WG_PRIV,
            wg,
            dns,
        )
        .unwrap();

        // Pre-seed the process globals (the test seam: set() bypasses
        // get_or_try_init, so no Redis hydration and a mock WG client).
        // set() errors (with the prior value) if the cell is already
        // full — a loud tripwire against two tests sharing a singleton.
        assert!(
            CONTROL_PLANE.set(cp_owned).is_ok(),
            "control plane set once"
        );
        // The forwarder's content is identical across tests (a default
        // live forwarder), so a losing `set()` here just means another
        // test seeded it first — reuse, don't trip.
        let _ = FORWARDER.set(Forwarder::new_live(Config::default()).unwrap());

        let cp = control_plane();
        let forwarder = forwarder();

        // Boot step: install the edge's identity into wg0 once. The
        // test's set() seam bypasses init_globals, so do the boot
        // install explicitly to mirror production.
        cp.install_edge_identity().expect("install edge identity");

        // Robustness against a reused Redis: a previous run (or aborted
        // one) leaves machines + allocation counters behind, which
        // breaks the "fresh store" assertions below. Clean the keys this
        // test owns so it passes on every run, not just a pristine store.
        for leftover in ["alicia", "robert", "carolyn"] {
            let _ = cp.delete(leftover).await;
        }
        let mut conn = cp.conn().await.unwrap();
        let _: () = conn.del(ALLOC_COUNTER).await.unwrap();
        let _: () = conn.del(MACHINE_INDEX).await.unwrap();
        // The cleanup above recorded mock WG/DNS calls; reset the
        // counters so the assertions below count only this test's
        // activity, not the leftover teardown.
        wg.removed.lock().unwrap().clear();
        dns.removes.lock().unwrap().clear();
        dns.upserts.lock().unwrap().clear();

        let first_pub = generate_wg_keypair().0;
        let second_pub = generate_wg_keypair().0;
        let SignupOutcome::Created(first) = cp
            .allocate_machine(None, "alicia", &first_pub)
            .await
            .expect("first allocation")
        else {
            panic!("first allocation created");
        };
        let SignupOutcome::Created(second) = cp
            .allocate_machine(
                Some("11111111-1111-4111-8111-111111111111"),
                "robert",
                &second_pub,
            )
            .await
            .expect("second allocation")
        else {
            panic!("second allocation created");
        };
        assert_ne!(first.machine.ipv6, second.machine.ipv6);
        assert_eq!(first.machine.ipv6, "2a01:4f8:c17:1::2");
        assert_eq!(first.machine.wg_ip, "10.10.0.2");
        assert_eq!(second.machine.ipv6, "2a01:4f8:c17:1::3");
        assert_eq!(second.machine.wg_ip, "10.10.0.3");
        // Name is the id: DNS records were provisioned for both.
        assert_eq!(first.machine.name, "alicia");
        assert_eq!(first.machine.hostname, "alicia.proletariat.tech");
        assert_eq!(first.machine.owner, None, "operator path is owner-less");
        assert_eq!(
            second.machine.owner.as_deref(),
            Some("11111111-1111-4111-8111-111111111111"),
            "owner carried onto the record"
        );
        assert_eq!(dns.upserts.lock().unwrap().len(), 4); // 2 machines × 2 records

        // The edge's public key is stable across signups (from the shared
        // store-held key, never regenerated) and matches GET /pubkey —
        // the customer can configure its WG peer for the edge from the
        // response.
        assert!(!first.edge_public_key.is_empty());
        assert_eq!(first.edge_public_key, second.edge_public_key);
        let pubkey = cp.edge_public_key().expect("edge pubkey");
        assert_eq!(pubkey, first.edge_public_key);
        // The shared private key was installed into the interface once
        // (on boot), not per-signup.
        assert_eq!(wg.private_keys.lock().unwrap().len(), 1);
        // The shared-identity property (ADR-029): the installed private
        // key IS the store-held one, so both nodes answer as the same
        // peer.
        assert_eq!(wg.private_keys.lock().unwrap()[0], TEST_EDGE_WG_PRIV);

        // The forwarder bound 4 live listeners (2 machines × 2 ports); the
        // WG client added both peers to the kernel interface.
        assert_eq!(forwarder.stats().forwards.len(), 4);
        assert!(forwarder.stats().forwards.iter().all(|s| s.bound));
        assert_eq!(wg.added.lock().unwrap().len(), 2);

        let machines = cp.list().await.expect("list");
        assert_eq!(machines.len(), 2);

        // Idempotent re-allocation: same name + same key returns the
        // existing route (no new /128, no new DNS, no new forwarder
        // bind) and re-ensures the WG peer.
        let dns_before = dns.upserts.lock().unwrap().len();
        let forwards_before = forwarder.stats().forwards.len();
        let SignupOutcome::Existing(first_again) = cp
            .allocate_machine(None, "alicia", &first_pub)
            .await
            .expect("idempotent re-allocation")
        else {
            panic!("same-key re-allocation is Existing");
        };
        assert_eq!(first_again.machine.ipv6, first.machine.ipv6, "same route");
        assert_eq!(first_again.machine.wg_ip, first.machine.wg_ip, "same route");
        assert_eq!(first_again.machine.wg_public_key, first_pub);
        assert_eq!(dns.upserts.lock().unwrap().len(), dns_before, "no new DNS");
        assert_eq!(
            forwarder.stats().forwards.len(),
            forwards_before,
            "no new forwarder bind"
        );
        assert_eq!(wg.added.lock().unwrap().len(), 3, "peer re-ensured");

        // Rotation: same name + a DIFFERENT key removes the old peer,
        // adds the new key on the SAME /128 + wg_ip, and persists it.
        let new_pub = generate_wg_keypair().0;
        let SignupOutcome::Existing(rotated) = cp
            .allocate_machine(None, "alicia", &new_pub)
            .await
            .expect("rotate")
        else {
            panic!("rotation is Existing");
        };
        assert_eq!(
            rotated.machine.ipv6, first.machine.ipv6,
            "rotation keeps /128"
        );
        assert_eq!(
            rotated.machine.wg_ip, first.machine.wg_ip,
            "rotation keeps wg_ip"
        );
        assert_eq!(
            rotated.machine.wg_public_key, new_pub,
            "stored pubkey updated"
        );
        assert_eq!(
            dns.upserts.lock().unwrap().len(),
            dns_before,
            "rotation no new DNS"
        );
        assert!(
            wg.removed.lock().unwrap().contains(&first_pub),
            "old peer removed on rotation"
        );
        assert_eq!(
            wg.added.lock().unwrap().len(),
            4,
            "new peer added on rotation"
        );

        // A fresh allocation still gets host 4: the idempotent
        // re-allocation and rotation burned no /128.
        let third_pub = generate_wg_keypair().0;
        let SignupOutcome::Created(third) = cp
            .allocate_machine(None, "carolyn", &third_pub)
            .await
            .expect("third allocation")
        else {
            panic!("carolyn created");
        };
        assert_eq!(
            third.machine.ipv6, "2a01:4f8:c17:1::4",
            "no wasted allocation"
        );

        // The rotated key is what persisted: a subsequent allocation with it
        // is an Existing no-op.
        let SignupOutcome::Existing(alicia_now) = cp
            .allocate_machine(None, "alicia", &new_pub)
            .await
            .expect("alicia current key")
        else {
            panic!("alicia current key is Existing");
        };
        assert_eq!(alicia_now.machine.wg_public_key, new_pub);

        let machines = cp.list().await.expect("list with carolyn");
        assert_eq!(machines.len(), 3);

        cp.delete(&first.machine.name).await.expect("delete first");
        // Rotation already removed alicia's first key, so the delete
        // removes the rotated key too (2 removals total for alicia).
        assert_eq!(forwarder.stats().forwards.len(), 4);
        assert_eq!(wg.removed.lock().unwrap().len(), 2);
        // Deleting removed the machine's DNS records (2 per machine).
        assert_eq!(dns.removes.lock().unwrap().len(), 2);

        let machines = cp.list().await.expect("list after delete");
        assert_eq!(machines.len(), 2);
        assert_eq!(machines[0].name, second.machine.name);

        cp.delete(&second.machine.name)
            .await
            .expect("delete second");
        assert!(matches!(
            cp.delete(&second.machine.name).await,
            Err(ControlPlaneError::NotFound(_))
        ));
        assert_eq!(forwarder.stats().forwards.len(), 2);
    }

    /// The name policy (ADR-032): ≥6 chars, reserved words refused,
    /// structure still enforced. Tripwire — a future edit that drops a
    /// check silently reopens the squatting surface.
    #[test]
    fn machine_name_policy() {
        assert!(validate_machine_name("mainbox").is_ok(), "6 chars ok");
        assert!(validate_machine_name("living-room").is_ok());
        assert!(
            validate_machine_name("a".repeat(63).as_str()).is_ok(),
            "63 chars ok"
        );
        assert!(
            validate_machine_name("main").is_err(),
            "5 chars rejected (anti-squat floor)"
        );
        assert!(validate_machine_name("home").is_err());
        assert!(validate_machine_name("www").is_err(), "reserved");
        assert!(
            validate_machine_name("jellyfin").is_err(),
            "reserved service label"
        );
        assert!(validate_machine_name("-lead").is_err(), "leading hyphen");
        assert!(validate_machine_name("trail-").is_err(), "trailing hyphen");
        assert!(validate_machine_name("do--uble").is_err(), "double hyphen");
        assert!(validate_machine_name("Upper").is_err(), "uppercase");
        assert!(
            validate_machine_name(&"x".repeat(64)).is_err(),
            "64 chars rejected"
        );
    }

    // ── HTTP API endpoint tests ──────────────────────────────────
    //
    // The auth gate and the OpenAPI spec are testable without Redis or
    // the process globals: auth fails during request extraction (before
    // the handler body runs), and the spec is derived from the code. So
    // these run against the real `app()` in any environment. The
    // /wireguard/* *handlers* need the control-plane global + a live
    // store (covered by `redis_store_round_trip`), so here we assert
    // only the spec-level facts about them. The /api/users/* handlers
    // read the injected `AppState` (not the globals), so their full
    // round trip is covered by `api_users_round_trip` when REDIS_URL is
    // set.

    use poem::http::StatusCode;
    use poem::test::TestClient;

    /// POST a device route without a bearer header → 401 (auth fails at
    /// extraction, before the handler reads any global).
    #[tokio::test]
    async fn wireguard_new_requires_auth() {
        let resp = TestClient::new(app())
            .post("/api/wireguard/new")
            .body_json(&serde_json::json!({ "name": "carolyn" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn wireguard_list_requires_auth() {
        let resp = TestClient::new(app()).get("/api/wireguard").send().await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn wireguard_delete_requires_auth() {
        let resp = TestClient::new(app())
            .delete("/api/wireguard/carol")
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
    async fn wireguard_new_rejects_missing_scheme() {
        let resp = TestClient::new(app())
            .post("/api/wireguard/new")
            .body_json(&serde_json::json!({ "name": "carolyn" }))
            .header("Authorization", "carol")
            .send()
            .await;
        // No `Bearer` scheme → not a valid bearer token → 401, without
        // consulting the admin hash.
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    /// The OpenAPI spec is derived from the code: every protected
    /// wireguard operation must carry the bearer security requirement,
    /// `/wireguard/pubkey` and the `/users/*` ops must be unguarded, and
    /// the spec declares the `/api` server base so try-it-out resolves.
    /// This is the tripwire that keeps the auth gate wired — a future
    /// edit that drops `_auth: AdminKey` from a handler silently opens
    /// that operation, and this test catches it.
    #[tokio::test]
    async fn spec_gates_protected_ops_and_leaves_public_ops_open() {
        let resp = TestClient::new(app()).get("/api/openapi.json").send().await;
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

        // wireguard new/list/delete require the scheme.
        for (path, methods) in [
            ("/wireguard/new", &["post"][..]),
            ("/wireguard", &["get"][..]),
            ("/wireguard/{name}", &["delete"][..]),
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

        // /wireguard/pubkey and the /users/* ops are unguarded (no
        // security requirement — pubkey is a public key, users are the
        // public account lifecycle whose session token IS the auth).
        for (path, method) in [
            ("/wireguard/pubkey", "get"),
            ("/users/register", "post"),
            ("/users/login", "post"),
            ("/users/verify", "post"),
            ("/users/reset_password", "post"),
            ("/users/reset_password/confirm", "post"),
        ] {
            let op = paths
                .get(path)
                .unwrap_or_else(|| panic!("{path} in spec"))
                .get(method)
                .unwrap_or_else(|| panic!("{method} op in {path}"));
            assert!(
                op.get("security").is_none(),
                "{path} {method} declares NO security requirement"
            );
        }

        // The spec declares the /api server base (poem-openapi's
        // `.server("/api")`), so swagger try-it-out hits the real paths.
        let servers = spec.get("servers").expect("servers present");
        let urls: Vec<&str> = servers
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|s| s.get("url").and_then(|u| u.as_str()))
            .collect();
        assert!(
            urls.contains(&"/api"),
            "spec server base is /api (got {urls:?})"
        );
    }

    /// The swagger UI is served at /api/docs (one doc for the whole API).
    #[tokio::test]
    async fn swagger_ui_served_at_api_docs() {
        let resp = TestClient::new(app()).get("/api/docs").send().await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("swagger"), "swagger UI served at /api/docs");
    }

    /// The edge serves health from the same handler as the API: /api/healthz
    /// is reachable on app() (no separate health listener). /api/healthz
    /// always returns ok\n without touching the status func, so it works
    /// even when the process globals aren't initialized.
    #[tokio::test]
    async fn health_merged_into_api_handler() {
        let resp = TestClient::new(app()).get("/api/healthz").send().await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert_eq!(body, "ok\n");
    }

    /// Full `/api/users/*` round trip against a real Redis with injected
    /// deps (no process globals — the users handlers read the injected
    /// `AppState`): register → the mock mailer captures the magic link →
    /// login refused pre-verify (403) → verify → login issues a session
    /// token → wrong password 401 → reset + confirm → new password logs
    /// in. Skipped unless REDIS_URL is set.
    /// Full invite-enrollment round trip over the HTTP API: register +
    /// verify an account → session → create invite → machine begins →
    /// approve names it → poll delivers the tunnel config + device
    /// token once → the token rotates the key without AdminKey. Skipped
    /// unless REDIS_URL is set.
    #[cfg(feature = "redis-tests")]
    #[tokio::test]
    async fn api_invites_round_trip() {
        use crate::controlplane::dns::MockDnsApiClient;
        use crate::controlplane::mail::MockMailer;
        use crate::controlplane::wg::MockWgClient;

        let url = match std::env::var("REDIS_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipping: REDIS_URL not set");
                return;
            }
        };
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").unwrap();
        let cp = Box::leak(Box::new(
            ControlPlane::with_deps(
                &url,
                subnet,
                wg_subnet,
                "example.net",
                TEST_EDGE_WG_PRIV,
                wg,
                dns,
            )
            .expect("control plane connects")
            .isolated_alloc(Box::leak(
                format!("fortress:test-alloc:api1-{}", std::process::id()).into_boxed_str(),
            )),
        ));
        // The store persists across runs: a prior aborted run may have
        // left this test's machine behind. Clean it so this test owns
        // its name every run. (After the forwarder is seeded — delete
        // unwires through the process global.)
        set_forwarder_for_tests();
        let _ = cp.delete("apibox1").await;
        let _ = cp.delete("apibox2").await;
        let mailer: &'static MockMailer = Box::leak(Box::new(MockMailer::new()));
        let status_func: StatusFunc = Arc::new(|| serde_json::Value::Null);
        let client = TestClient::new(app_with(status_func, Some(cp), Some(mailer)));

        use std::time::{SystemTime, UNIX_EPOCH};
        let email = format!(
            "inv-{}-{}@example.com",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );

        // Register → verify → login (session token IS the auth).
        client
            .post("/api/users/register")
            .body_json(&serde_json::json!({ "email": email, "password": "hunter2" }))
            .send()
            .await;
        let verify_token = extract_api_token(&mailer.sent()[0].body);
        client
            .post("/api/users/verify")
            .body_json(&serde_json::json!({ "token": verify_token }))
            .send()
            .await;
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "hunter2" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        let session = body["token"].as_str().unwrap().to_string();

        // No session → 401 on every owner op.
        let resp = client.post("/api/invites").send().await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
        let resp = client
            .post("/api/invites/abcdefghjk/approve")
            .body_json(&serde_json::json!({ "name": "mainbox" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);

        // Create an invite with the session.
        let resp = client
            .post("/api/invites")
            .header("cookie", format!("fortress_account_session={session}"))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::CREATED);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        let code = body["code"].as_str().unwrap().to_string();
        assert_eq!(code.len(), 10);
        assert_eq!(body["url"], format!("https://example.net/a/{code}"));

        // The machine begins.
        let machine_pub = generate_wg_keypair().0;
        let resp = client
            .post(format!("/api/invites/{code}/begin"))
            .body_json(&serde_json::json!({ "public_key": machine_pub }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        assert_eq!(body["status"], "waiting");

        // Approve names it. The name must be unique across the WHOLE
        // (shared) store — "apibox1" is this test's own, never
        // reused by another test.
        let resp = client
            .post(format!("/api/invites/{code}/approve"))
            .header("cookie", format!("fortress_account_session={session}"))
            .body_json(&serde_json::json!({ "name": "apibox1" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK, "approve accepted");

        // Poll delivers the payload once.
        let resp = client.get(format!("/api/invites/{code}/poll")).send().await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        assert_eq!(body["status"], "approved");
        assert_eq!(body["machine"]["name"], "apibox1");
        assert_eq!(body["machine"]["hostname"], "apibox1.example.net");
        let device_token = body["deviceToken"].as_str().unwrap().to_string();

        // Device rotation through the API, no cookie, no AdminKey.
        let new_pub = generate_wg_keypair().0;
        let resp = client
            .post("/api/device/register")
            .body_json(&serde_json::json!({ "device_token": device_token, "public_key": new_pub }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        assert_eq!(body["machine"]["wg_public_key"], new_pub, "pubkey rotated");

        // A wrong token is unauthorized.
        let resp = client
            .post("/api/device/register")
            .body_json(&serde_json::json!({ "device_token": "nope", "public_key": new_pub }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);

        // Account deletion: unwires the machine, kills the session.
        let resp = client
            .delete("/api/account")
            .header("cookie", format!("fortress_account_session={session}"))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        // The (now dead) session can no longer reach owner ops.
        let resp = client
            .get("/api/invites")
            .header("cookie", format!("fortress_account_session={session}"))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
        // The machine is gone from the store.
        let machines = cp.list().await.expect("list");
        assert!(!machines.iter().any(|m| m.name == "apibox1"));
        // A fresh login fails (the record is gone).
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "hunter2" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
    }

    #[cfg(feature = "redis-tests")]
    #[tokio::test]
    async fn api_users_round_trip() {
        use crate::controlplane::dns::MockDnsApiClient;
        use crate::controlplane::mail::MockMailer;
        use crate::controlplane::wg::MockWgClient;

        let url = match std::env::var("REDIS_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipping: REDIS_URL not set");
                return;
            }
        };
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").unwrap();
        let cp = Box::leak(Box::new(
            ControlPlane::with_deps(
                &url,
                subnet,
                wg_subnet,
                "example.net",
                TEST_EDGE_WG_PRIV,
                wg,
                dns,
            )
            .expect("control plane connects")
            .isolated_alloc(Box::leak(
                format!("fortress:test-alloc:api2-{}", std::process::id()).into_boxed_str(),
            )),
        ));
        let mailer: &'static MockMailer = Box::leak(Box::new(MockMailer::new()));
        let status_func: StatusFunc = Arc::new(|| serde_json::Value::Null);
        let client = TestClient::new(app_with(status_func, Some(cp), Some(mailer)));

        use std::time::{SystemTime, UNIX_EPOCH};
        let email = format!(
            "api-{}-{}@example.com",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );

        // Register → 201 + the mailer captured the magic link.
        let resp = client
            .post("/api/users/register")
            .body_json(&serde_json::json!({ "email": email, "password": "hunter2" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::CREATED);
        let sent = mailer.sent();
        assert_eq!(sent.len(), 1);
        let verify_token = extract_api_token(&sent[0].body);

        // Login is refused before verification (403, not "no such user").
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "hunter2" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::FORBIDDEN);

        // Verify → 200.
        let resp = client
            .post("/api/users/verify")
            .body_json(&serde_json::json!({ "token": verify_token }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);

        // Login → 200 + session token.
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "hunter2" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        assert!(body.get("token").is_some(), "login returns a session token");

        // Wrong password → 401 (generic, no enumeration).
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "nope" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);

        // Reset: request (known email → explicit sent message) → confirm
        // with the link token → the new password logs in, the old one
        // doesn't.
        let resp = client
            .post("/api/users/reset_password")
            .body_json(&serde_json::json!({ "email": email }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let body: serde_json::Value = resp.0.into_body().into_json().await.unwrap();
        assert!(
            body["message"]
                .as_str()
                .unwrap()
                .contains("a reset link is on its way")
        );
        let reset_token = extract_api_token(&mailer.sent()[1].body);
        let resp = client
            .post("/api/users/reset_password/confirm")
            .body_json(&serde_json::json!({ "token": reset_token, "password": "new-password" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "old-password" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::UNAUTHORIZED);
        let resp = client
            .post("/api/users/login")
            .body_json(&serde_json::json!({ "email": email, "password": "new-password" }))
            .send()
            .await;
        assert_eq!(resp.0.status(), StatusCode::OK);
    }

    /// The magic-link bodies are `…token=<hex>…`; pull the token out.
    fn extract_api_token(body: &str) -> String {
        let start = body.find("token=").expect("link present") + "token=".len();
        body[start..].lines().next().unwrap().trim().to_string()
    }
}
