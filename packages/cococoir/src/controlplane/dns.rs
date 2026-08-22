// SPDX-License-Identifier: AGPL-3.0-or-later
//! DNS provisioning + resolution.
//!
//! Two independent concerns, deliberately split:
//!
//! 1. **Provisioning** — `DnsApiClient` talks to a DNS *provider's*
//!    write API (today: Hetzner). One record per call, full record
//!    name, typed IPv6. Swappable provider behind a small trait, the
//!    way `WgClient` swaps the kernel-interface backend. Config is
//!    immutable process-lifetime data (`LazyLock` static), read from
//!    the resolved secrets at boot — never changed without a restart.
//!
//! 2. **Resolution** — `resolve_aaaa` queries a public resolver
//!    (1.1.1.1) and returns the AAAA set for a name. Used only to
//!    *verify* that provisioned records are actually published, so a
//!    background reconcile loop can re-apply drift. This is NOT part
//!    of the provisioning client — provisioning and resolution are
//!    different providers that can be swapped independently.
//!
//! The customer-naming policy (main + wildcard record under the root
//! domain) lives ABOVE this module, in the orchestrator
//! (`upsert_customer`/`remove_customer`). The provider client never
//! constructs a name; the naming layer never talks to a provider. The
//! root domain is passed in by callers (from `secret::root_domain()`),
//! keeping the naming functions pure and testable without a global.

use std::net::Ipv6Addr;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use async_trait::async_trait;

use crate::controlplane::secret::SECRETS;

/// Errors from DNS provisioning or resolution.
#[derive(Debug, Error)]
pub enum DnsError {
    #[error("dns config: {0}")]
    Config(String),
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("dns api: {0}")]
    Api(String),
    #[error("resolution failed: {0}")]
    Resolve(String),
}

/// A client for a DNS provider's provisioning API. One record per
/// call; `name` is the FULL record name (e.g. `*.bob.interdim.net`).
/// The "main + wildcard" policy lives above this (see the module doc).
#[async_trait]
pub trait DnsApiClient: Send + Sync {
    /// Create or update the AAAA record at `name` to point at `ipv6`.
    /// Idempotent.
    async fn upsert_aaaa(&self, name: &str, ipv6: Ipv6Addr) -> Result<(), DnsError>;
    /// Remove the AAAA record at `name`. A missing record is not an
    /// error.
    async fn remove_aaaa(&self, name: &str) -> Result<(), DnsError>;
}

/// Hetzner DNS API base URL.
const HETZNER_BASE: &str = "https://dns.hetzner.com/api/v1";

/// A record as returned by the Hetzner DNS API.
#[derive(Debug, Deserialize)]
struct HetznerRecord {
    id: String,
    #[serde(rename = "type")]
    type_: String,
    name: String,
    value: String,
}

/// The payload Hetzner's create/update record endpoints expect.
#[derive(Debug, Serialize)]
struct NewRecord<'a> {
    #[serde(rename = "type")]
    type_: &'static str,
    name: &'a str,
    value: String,
    zone_id: &'a str,
    ttl: u32,
}

#[derive(Debug, Deserialize)]
struct RecordsResponse {
    records: Vec<HetznerRecord>,
}

/// The real provisioning client: talks to Hetzner's DNS API.
///
/// Holds the provider's own config — zone id, zone name (the apex this
/// client writes into; Hetzner's API takes record names *relative* to
/// the zone, so the full name must be stripped against it), and token.
/// Nothing about customer naming: `DOMAIN` (naming) is a separate
/// global above this struct.
#[derive(Clone)]
pub struct HetznerDns {
    zone_id: String,
    zone_name: String,
    token: String,
    /// Built on first HTTP use, not at construction — so building a
    /// `HetznerDns` (e.g. in a pure-logic test, or the nix build sandbox
    /// where there are no CA certs) never touches reqwest. The client is
    /// only needed for actual Hetzner API calls.
    http: std::sync::OnceLock<reqwest::Client>,
}

impl HetznerDns {
    /// Build from the resolved edge secrets. The three zone/token values
    /// come from `SECRETS` (see `secret.rs`); missing config panics in
    /// that `LazyLock` (fail-fast at boot), never on a first DNS call.
    fn from_secrets() -> Self {
        let s = &SECRETS.secrets;
        Self::new(
            s.dns_zone_id.clone(),
            s.dns_zone_name.clone(),
            s.dns_token.clone(),
        )
    }

    /// Construct from explicit config — the test seam for
    /// [`HetznerDns::from_secrets`], which reads the same three values
    /// from the resolved secrets.
    pub(crate) fn new(zone_id: String, zone_name: String, token: String) -> Self {
        Self {
            zone_id,
            zone_name,
            token,
            http: std::sync::OnceLock::new(),
        }
    }

    fn http(&self) -> &reqwest::Client {
        // The client is built only on first real API use. Building it
        // panics in an environment with no CA certs (a build sandbox),
        // which never makes API calls — so lazy construction keeps a
        // pure-logic test (or the nix `cargo test`) from ever touching
        // reqwest. On the live box the certs exist, so this resolves
        // once and is reused for the process lifetime.
        self.http.get_or_init(reqwest::Client::new)
    }

    /// The record name Hetzner's API expects: the full name with the
    /// zone apex stripped (records under the apex itself use `@`).
    fn relative_name(&self, full: &str) -> Result<String, DnsError> {
        let zone = self.zone_name.trim_end_matches('.');
        let full = full.trim_end_matches('.');
        if full == zone {
            return Ok("@".to_string());
        }
        full.strip_suffix(&format!(".{zone}"))
            .map(str::to_string)
            .ok_or_else(|| {
                DnsError::Api(format!("{full} is not under zone {zone}"))
            })
    }

    async fn get_records(&self, name: &str) -> Result<Vec<HetznerRecord>, DnsError> {
        let resp = self
            .http()
            .get(format!("{HETZNER_BASE}/records"))
            .header("Auth-API-Token", &self.token)
            .query(&[
                ("zone_id", self.zone_id.as_str()),
                ("name", name),
                ("type", "AAAA"),
            ])
            .send()
            .await?
            .error_for_status()?;
        let body: RecordsResponse = resp.json().await?;
        Ok(body.records)
    }

    async fn create_record(&self, name: &str, ipv6: Ipv6Addr) -> Result<(), DnsError> {
        let body = NewRecord {
            type_: "AAAA",
            name,
            value: ipv6.to_string(),
            zone_id: &self.zone_id,
            ttl: 3600,
        };
        self.http()
            .post(format!("{HETZNER_BASE}/records"))
            .header("Auth-API-Token", &self.token)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn update_record(&self, id: &str, name: &str, ipv6: Ipv6Addr) -> Result<(), DnsError> {
        let body = NewRecord {
            type_: "AAAA",
            name,
            value: ipv6.to_string(),
            zone_id: &self.zone_id,
            ttl: 3600,
        };
        self.http()
            .put(format!("{HETZNER_BASE}/records/{id}"))
            .header("Auth-API-Token", &self.token)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn delete_record(&self, id: &str) -> Result<(), DnsError> {
        self.http()
            .delete(format!("{HETZNER_BASE}/records/{id}"))
            .header("Auth-API-Token", &self.token)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

#[async_trait]
impl DnsApiClient for HetznerDns {
    async fn upsert_aaaa(&self, name: &str, ipv6: Ipv6Addr) -> Result<(), DnsError> {
        let relative = self.relative_name(name)?;
        let existing = self.get_records(&relative).await?;
        match existing.first() {
            Some(record) => {
                self.update_record(&record.id, &relative, ipv6).await?;
                // Self-heal duplicates: if a previous bug left extra
                // records for the same name, drop them so round-robin
                // doesn't alternate between correct and stale values.
                for dup in existing.iter().skip(1) {
                    self.delete_record(&dup.id).await?;
                }
            }
            None => self.create_record(&relative, ipv6).await?,
        }
        Ok(())
    }

    async fn remove_aaaa(&self, name: &str) -> Result<(), DnsError> {
        let relative = self.relative_name(name)?;
        let existing = self.get_records(&relative).await?;
        for record in existing {
            self.delete_record(&record.id).await?;
        }
        Ok(())
    }
}

/// A test client that records calls instead of hitting Hetzner.
/// `fail_upsert` simulates a provider outage for the "DNS failure does
/// not fail a signup" guarantee.
#[derive(Debug, Default)]
pub struct MockDnsApiClient {
    pub upserts: std::sync::Mutex<Vec<(String, Ipv6Addr)>>,
    pub removes: std::sync::Mutex<Vec<String>>,
    fail_upsert: std::sync::atomic::AtomicBool,
}

impl MockDnsApiClient {
    pub fn new() -> Self {
        Self::default()
    }

    /// Make subsequent `upsert_aaaa` calls fail (provider outage).
    pub fn fail_upserts(&self) {
        self.fail_upsert.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

#[async_trait]
impl DnsApiClient for MockDnsApiClient {
    async fn upsert_aaaa(&self, name: &str, ipv6: Ipv6Addr) -> Result<(), DnsError> {
        if self.fail_upsert.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DnsError::Api("mock provider outage".to_string()));
        }
        self.upserts
            .lock()
            .unwrap()
            .push((name.to_string(), ipv6));
        Ok(())
    }

    async fn remove_aaaa(&self, name: &str) -> Result<(), DnsError> {
        self.removes.lock().unwrap().push(name.to_string());
        Ok(())
    }
}

/// Query a public resolver (1.1.1.1) for the AAAA records at `name`.
/// Independent of provisioning — the reconcile loop uses it to verify
/// that provisioned records are actually published.
pub async fn resolve_aaaa(name: &str) -> Result<Vec<Ipv6Addr>, DnsError> {
    use hickory_resolver::config::ResolverConfig;
    use hickory_resolver::net::runtime::TokioRuntimeProvider;
    let config = ResolverConfig::udp_and_tcp(&hickory_resolver::config::CLOUDFLARE);
    let resolver = hickory_resolver::Resolver::builder_with_config(
        config,
        TokioRuntimeProvider::default(),
    )
    .build()
    .map_err(|err| DnsError::Resolve(err.to_string()))?;
    let lookup = resolver
        .lookup_ip(name)
        .await
        .map_err(|err| DnsError::Resolve(err.to_string()))?;
    Ok(lookup
        .iter()
        .filter_map(|ip| match ip {
            std::net::IpAddr::V6(v6) => Some(v6),
            _ => None,
        })
        .collect())
}

/// The single provider config global. Immutable process-lifetime data
/// (see `writing/human/lifetimes_in_rust.md`): built once from the
/// resolved secrets at first access, never changed without a restart.
static DNS_CLIENT: LazyLock<HetznerDns> = LazyLock::new(HetznerDns::from_secrets);

/// The process's provisioning client. Panics if the secrets failed to
/// resolve — unreachable in production because `init_globals` forces
/// `SECRETS` (fail-fast at boot) first.
pub fn get_dns_api() -> &'static dyn DnsApiClient {
    &*DNS_CLIENT
}

/// Create the AAAA records for a customer: the bare hostname and the
/// wildcard, both → the customer's `/128`. Runs both concurrently; a
/// failure leaves the other record applied, and a retry (signup or the
/// reconcile loop) self-heals it because each upsert is idempotent.
pub async fn upsert_customer(
    dns: &dyn DnsApiClient,
    username: &str,
    ipv6: Ipv6Addr,
    domain: &str,
) -> Result<(), DnsError> {
    let host = customer_hostname(username, domain);
    let wildcard = format!("*.{host}");
    let (main, wild) = tokio::join!(
        dns.upsert_aaaa(&host, ipv6),
        dns.upsert_aaaa(&wildcard, ipv6)
    );
    main?;
    wild?;
    Ok(())
}

/// Remove the AAAA records for a customer (bare hostname + wildcard).
pub async fn remove_customer(
    dns: &dyn DnsApiClient,
    username: &str,
    domain: &str,
) -> Result<(), DnsError> {
    let host = customer_hostname(username, domain);
    let wildcard = format!("*.{host}");
    let (main, wild) = tokio::join!(
        dns.remove_aaaa(&host),
        dns.remove_aaaa(&wildcard)
    );
    main?;
    wild?;
    Ok(())
}

/// The customer's bare hostname, e.g. `bob.interdim.net`.
pub fn customer_hostname(username: &str, domain: &str) -> String {
    format!("{username}.{domain}")
}

/// Does the resolved AAAA set satisfy the record we want? A customer
/// is served correctly only if their `/128` is present.
pub fn aaaa_matches(resolved: &[Ipv6Addr], expected: Ipv6Addr) -> bool {
    resolved.contains(&expected)
}

/// A resolver function: returns the AAAA set for a name. Boxed future
/// so the type is concrete (a bare `async fn` with a borrowed arg
/// can't satisfy a higher-ranked `Fn` bound), and so tests can inject
/// a fake.
pub type AaaaResolver = for<'a> fn(
    &'a str,
) -> std::pin::Pin<
    Box<dyn std::future::Future<Output = Result<Vec<Ipv6Addr>, DnsError>> + Send + 'a>,
>;

/// Boxed wrapper over [`resolve_aaaa`] — the production resolver,
/// passed to [`reconcile_pass`] as a concrete `AaaaResolver`.
pub fn resolve_aaaa_boxed(
    name: &str,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Vec<Ipv6Addr>, DnsError>> + Send + '_>>
{
    Box::pin(resolve_aaaa(name))
}

/// One reconcile pass over the customer set: verify both records for
/// each customer against real resolution and re-apply mismatches.
/// `resolve` is injectable so tests can fake the resolver; production
/// passes [`resolve_aaaa_boxed`]. Returns the number of records
/// re-applied.
pub async fn reconcile_pass(
    dns: &dyn DnsApiClient,
    customers: &[(String, Ipv6Addr)],
    resolve: AaaaResolver,
    domain: &str,
) -> usize {
    let mut reapplied = 0usize;
    for (username, ipv6) in customers {
        let host = customer_hostname(username, domain);
        let wildcard = format!("*.{host}");
        for name in [host, wildcard] {
            let resolved = match resolve(&name).await {
                Ok(ips) => ips,
                Err(err) => {
                    tracing::warn!(name = %name, err = %err, "reconcile: resolution failed, reapplying");
                    if let Err(err) = dns.upsert_aaaa(&name, *ipv6).await {
                        tracing::error!(name = %name, err = %err, "reconcile: reapply failed");
                    } else {
                        reapplied += 1;
                    }
                    continue;
                }
            };
            if aaaa_matches(&resolved, *ipv6) {
                continue;
            }
            tracing::warn!(name = %name, ipv6 = %ipv6, resolved = ?resolved, "reconcile: record mismatch, reapplying");
            if let Err(err) = dns.upsert_aaaa(&name, *ipv6).await {
                tracing::error!(name = %name, err = %err, "reconcile: reapply failed");
            } else {
                reapplied += 1;
            }
        }
    }
    reapplied
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider() -> HetznerDns {
        HetznerDns::new(
            "zone-123".to_string(),
            "interdim.net".to_string(),
            "secret-token".to_string(),
        )
    }

    #[test]
    fn relative_name_strips_zone() {
        let dns = provider();
        assert_eq!(dns.relative_name("bob.interdim.net").unwrap(), "bob");
        assert_eq!(
            dns.relative_name("*.bob.interdim.net").unwrap(),
            "*.bob"
        );
        assert_eq!(dns.relative_name("interdim.net").unwrap(), "@");
        assert!(dns.relative_name("bob.example.org").is_err());
    }

    #[tokio::test]
    async fn mock_records_upsert_and_remove() {
        let mock = MockDnsApiClient::new();
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        mock.upsert_aaaa("bob.interdim.net", ip).await.unwrap();
        mock.upsert_aaaa("*.bob.interdim.net", ip).await.unwrap();
        mock.remove_aaaa("bob.interdim.net").await.unwrap();
        let upserts = mock.upserts.lock().unwrap();
        assert_eq!(upserts.len(), 2);
        assert_eq!(upserts[0], ("bob.interdim.net".to_string(), ip));
        assert_eq!(upserts[1], ("*.bob.interdim.net".to_string(), ip));
        assert_eq!(*mock.removes.lock().unwrap(), vec!["bob.interdim.net".to_string()]);
    }

    #[tokio::test]
    async fn mock_fail_upsert_returns_err() {
        let mock = MockDnsApiClient::new();
        mock.fail_upserts();
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        assert!(mock.upsert_aaaa("bob.interdim.net", ip).await.is_err());
    }

    #[test]
    fn customer_hostname_uses_domain() {
        assert!(customer_hostname("bob", "interdim.net").ends_with(".interdim.net"));
        assert!(customer_hostname("bob", "other.example").ends_with(".other.example"));
    }

    #[tokio::test]
    async fn upsert_customer_creates_both_records() {
        let mock = MockDnsApiClient::new();
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        upsert_customer(&mock, "bob", ip, "interdim.net").await.unwrap();
        let upserts = mock.upserts.lock().unwrap();
        assert_eq!(upserts.len(), 2);
        let names: Vec<&str> = upserts.iter().map(|(n, _)| n.as_str()).collect();
        assert!(names.contains(&"bob.interdim.net"));
        assert!(names.contains(&"*.bob.interdim.net"));
        assert!(upserts.iter().all(|(_, got)| *got == ip));
    }

    #[tokio::test]
    async fn remove_customer_removes_both_records() {
        let mock = MockDnsApiClient::new();
        remove_customer(&mock, "bob", "interdim.net").await.unwrap();
        let mut removes = mock.removes.lock().unwrap();
        removes.sort();
        assert_eq!(
            *removes,
            vec!["*.bob.interdim.net".to_string(), "bob.interdim.net".to_string()]
        );
    }

    #[test]
    fn aaaa_matches_checks_expected_present() {
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        let other: Ipv6Addr = "2a01:4f8:c17:1::3".parse().unwrap();
        assert!(aaaa_matches(&[ip, other], ip));
        assert!(!aaaa_matches(&[other], ip));
        assert!(!aaaa_matches(&[], ip));
    }

    #[tokio::test]
    async fn reconcile_reapplies_mismatch() {
        let mock = MockDnsApiClient::new();
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        let wrong: Ipv6Addr = "2a01:4f8:c17:1::9".parse().unwrap();
        // Fake resolver: both records resolve to the WRONG address.
        // Non-capturing (the addr is in a `static`) so it coerces to
        // the `AaaaResolver` fn pointer.
        static WRONG: std::net::Ipv6Addr = std::net::Ipv6Addr::new(0x2a01, 0x4f8, 0xc17, 1, 0, 0, 0, 9);
        let resolve: AaaaResolver = |_: &str| Box::pin(async move { Ok(vec![WRONG]) });
        let customers = vec![("bob".to_string(), ip)];
        let reapplied = reconcile_pass(&mock, &customers, resolve, "interdim.net").await;
        assert_eq!(reapplied, 2); // bare + wildcard both re-applied
        assert_eq!(mock.upserts.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn reconcile_skips_matching_records() {
        let mock = MockDnsApiClient::new();
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        // Fake resolver: both records already point at the right addr.
        static RIGHT: std::net::Ipv6Addr = std::net::Ipv6Addr::new(0x2a01, 0x4f8, 0xc17, 1, 0, 0, 0, 2);
        let resolve: AaaaResolver = |_: &str| Box::pin(async move { Ok(vec![RIGHT]) });
        let customers = vec![("bob".to_string(), ip)];
        let reapplied = reconcile_pass(&mock, &customers, resolve, "interdim.net").await;
        assert_eq!(reapplied, 0);
        assert_eq!(mock.upserts.lock().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn reconcile_reapplies_when_resolution_fails() {
        let mock = MockDnsApiClient::new();
        let ip: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        let resolve: AaaaResolver = |_: &str| {
            Box::pin(async move { Err::<Vec<Ipv6Addr>, DnsError>(DnsError::Resolve("boom".into())) })
        };
        let customers = vec![("bob".to_string(), ip)];
        let reapplied = reconcile_pass(&mock, &customers, resolve, "interdim.net").await;
        assert_eq!(reapplied, 2);
    }
}