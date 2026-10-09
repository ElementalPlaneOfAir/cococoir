//! The service catalog and its liveness.
//!
//! The catalog is rendered by Nix from the ADR-004 service contract
//! (`nix/lib/fortress.nix` `mkCatalog`) and passed to the client with
//! `-catalog <store path>`. The module system is the single source of
//! truth for what services exist and where they live; nothing in this
//! file decides that. What is decided here is whether a service is
//! answering *right now*, which only a running box can know.
//!
//! Liveness is a hint, not monitoring: a GET to `healthUrl` with a
//! short timeout, cached briefly, rendered as a dot. A service that is
//! up but slow shows grey — that is a property of the probe budget, not
//! a claim about the service.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;

/// One service as Nix renders it. Field names match
/// `nix/lib/fortress.nix` `mkCatalog` exactly — a mismatch is a card
/// with no link, so loading fails rather than rendering half a row.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct CatalogEntry {
    pub name: String,
    pub description: String,
    pub path: String,
    pub domain: String,
    pub port: u16,
    pub public: bool,
    #[serde(rename = "healthUrl")]
    pub health_url: String,
}

/// What the dashboard knows about the box's services.
#[derive(Debug, Clone, Default)]
pub struct Catalog {
    entries: Vec<CatalogEntry>,
}

impl Catalog {
    /// Read the Nix-rendered catalog. An unreadable or malformed file
    /// is a programmer error (the store path is baked into the unit at
    /// eval time), so it fails loudly instead of serving an empty page
    /// that looks like "no services configured".
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|err| format!("catalog {}: {err}", path.display()))?;
        let entries: Vec<CatalogEntry> = serde_json::from_str(&text)
            .map_err(|err| format!("catalog {}: {err}", path.display()))?;
        for entry in &entries {
            if entry.name.is_empty() {
                return Err(format!("catalog {}: an entry has an empty name", path.display()));
            }
            if entry.path.is_empty() || !entry.path.starts_with('/') {
                return Err(format!(
                    "catalog {}: {} has a path that is not absolute — a card would link nowhere",
                    path.display(),
                    entry.name
                ));
            }
            if entry.health_url.is_empty() {
                return Err(format!(
                    "catalog {}: {} has no healthUrl — liveness would silently show grey",
                    path.display(),
                    entry.name
                ));
            }
            if !entry.health_url.starts_with("http://") {
                return Err(format!(
                    "catalog {}: {} healthUrl must be plain http — the prober builds no root store, so an https target would silently probe down forever ({}).",
                    path.display(),
                    entry.name,
                    entry.health_url
                ));
            }
        }
        Ok(Self { entries })
    }

    /// Build a catalog from entries. Loading from the Nix-rendered file
    /// is the production path; this exists for tests and any in-memory
    /// source.
    pub fn from_entries(entries: Vec<CatalogEntry>) -> Self {
        Self { entries }
    }

    pub fn entries(&self) -> &[CatalogEntry] {
        &self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// How long a probe result stays believable. Long enough that a page
/// refresh does not stampede the services, short enough that a service
/// that died shows grey on the next look.
const CACHE_TTL: Duration = Duration::from_secs(30);
/// Per-probe budget. A hung service must not hold the page open.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// How many services are probed at once. A box with twenty services
/// must not open twenty sockets to find out they are all down.
const MAX_CONCURRENT_PROBES: usize = 8;

#[derive(Debug, Clone, Copy)]
struct CacheEntry {
    checked_at: Instant,
    healthy: bool,
}

/// Liveness for the catalog, cached briefly.
#[derive(Debug, Clone)]
pub struct Prober {
    http: reqwest::Client,
    cache: Arc<Mutex<HashMap<String, CacheEntry>>>,
}

impl Default for Prober {
    fn default() -> Self {
        Self::new()
    }
}

impl Prober {
    pub fn new() -> Self {
        assert!(CACHE_TTL > PROBE_TIMEOUT, "a cache TTL shorter than the probe timeout would re-probe before the first answer arrives");
        // tls_certs_only([]) builds a client with NO root store. The prober
        // only GETs `http://127.0.0.1:<port>` — the ADR-004 contract's
        // healthUrl is always loopback HTTP — so it never needs TLS. The
        // default, loading the *platform* root store, aborts outright where
        // there is none: the Nix build sandbox, and every customer box,
        // where the ADR-035 applier never materializes /etc/ssl/certs.
        let http = reqwest::Client::builder()
            .timeout(PROBE_TIMEOUT)
            .tls_certs_only([])
            .build()
            .expect("a reqwest client with a timeout and an empty root store cannot fail to build");
        Self {
            http,
            cache: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Liveness for every catalog entry, probing whatever has gone
    /// stale. Bounded concurrency; the returned booleans line up with
    /// `catalog`.
    pub async fn snapshot(&self, catalog: &Catalog) -> Vec<bool> {
        let entries = catalog.entries();
        let mut stale = Vec::new();
        let mut healthy = vec![false; entries.len()];
        {
            let cache = self.cache.lock().expect("liveness cache lock is poisoned");
            for (index, entry) in entries.iter().enumerate() {
                match cache.get(&entry.health_url) {
                    Some(hit) if hit.checked_at.elapsed() < CACHE_TTL => healthy[index] = hit.healthy,
                    _ => stale.push((index, entry.health_url.clone())),
                }
            }
        }
        if !stale.is_empty() {
            let semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_PROBES));
            let mut handles = Vec::with_capacity(stale.len());
            for (index, url) in stale {
                let permit = semaphore.clone();
                let http = self.http.clone();
                let cache = self.cache.clone();
                handles.push(tokio::spawn(async move {
                    let _permit = permit
                        .acquire_owned()
                        .await
                        .expect("a semaphore permit is always available eventually");
                    let ok = probe_one(&http, &url).await;
                    cache
                        .lock()
                        .expect("liveness cache lock is poisoned")
                        .insert(url, CacheEntry { checked_at: Instant::now(), healthy: ok });
                    (index, ok)
                }));
            }
            for handle in handles {
                match handle.await {
                    Ok((index, ok)) => healthy[index] = ok,
                    Err(err) => tracing::warn!(%err, "liveness probe task failed"),
                }
            }
        }
        healthy
    }
}

/// One GET. Any answer at all proves the service is listening, so only
/// transport errors count as down — a 401 or a 500 is a running service
/// with an opinion.
async fn probe_one(http: &reqwest::Client, url: &str) -> bool {
    match http.get(url).send().await {
        Ok(_) => true,
        Err(err) => {
            tracing::debug!(%url, %err, "liveness probe failed");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, path: &str, health_url: &str) -> CatalogEntry {
        CatalogEntry {
            name: name.to_string(),
            description: "desc".to_string(),
            path: path.to_string(),
            domain: format!("{name}.example.test"),
            port: 1234,
            public: true,
            health_url: health_url.to_string(),
        }
    }

    fn write_catalog(dir: &Path, text: &str) -> std::path::PathBuf {
        let path = dir.join("catalog.json");
        std::fs::write(&path, text).unwrap();
        path
    }

    #[test]
    fn load_reads_the_nix_shape() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_catalog(
            dir.path(),
            r#"[{"name":"jellyfin","description":"d","path":"/jellyfin","domain":"j.test","port":8096,"public":true,"healthUrl":"http://127.0.0.1:8096/health"}]"#,
        );
        let catalog = Catalog::load(&path).expect("valid catalog loads");
        assert_eq!(catalog.entries().len(), 1);
        assert_eq!(catalog.entries()[0].name, "jellyfin");
        assert_eq!(catalog.entries()[0].health_url, "http://127.0.0.1:8096/health");
    }

    #[test]
    fn load_rejects_a_relative_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_catalog(
            dir.path(),
            r#"[{"name":"x","description":"d","path":"jellyfin","domain":"x.test","port":1,"public":true,"healthUrl":"http://127.0.0.1/health"}]"#,
        );
        let err = Catalog::load(&path).expect_err("a relative path cannot be linked to");
        assert!(err.contains("not absolute"), "{err}");
    }

    #[test]
    fn load_rejects_a_missing_health_url() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_catalog(
            dir.path(),
            r#"[{"name":"x","description":"d","path":"/x","domain":"x.test","port":1,"public":true,"healthUrl":""}]"#,
        );
        let err = Catalog::load(&path).expect_err("no healthUrl means no liveness");
        assert!(err.contains("healthUrl"), "{err}");
    }

    #[test]
    fn load_rejects_malformed_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_catalog(dir.path(), "not json");
        assert!(Catalog::load(&path).is_err());
    }

    #[test]
    fn load_rejects_an_https_health_url() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_catalog(
            dir.path(),
            r#"[{"name":"x","description":"d","path":"/x","domain":"x.test","port":1,"public":true,"healthUrl":"https://127.0.0.1/health"}]"#,
        );
        let err = Catalog::load(&path).expect_err("the prober builds no root store, so https would silently probe down");
        assert!(err.contains("plain http"), "{err}");
    }

    #[tokio::test]
    async fn snapshot_marks_an_unreachable_service_down() {
        let prober = Prober::new();
        let catalog = Catalog {
            entries: vec![entry("gone", "/gone", "http://127.0.0.1:1/health")],
        };
        let healthy = prober.snapshot(&catalog).await;
        assert_eq!(healthy, vec![false]);
    }

    #[tokio::test]
    async fn snapshot_caches_rather_than_reprobing() {
        let prober = Prober::new();
        let catalog = Catalog {
            entries: vec![entry("gone", "/gone", "http://127.0.0.1:1/health")],
        };
        prober.snapshot(&catalog).await;
        let before = prober
            .cache
            .lock()
            .unwrap()
            .get("http://127.0.0.1:1/health")
            .map(|hit| hit.checked_at)
            .expect("first snapshot caches");
        prober.snapshot(&catalog).await;
        let after = prober
            .cache
            .lock()
            .unwrap()
            .get("http://127.0.0.1:1/health")
            .map(|hit| hit.checked_at)
            .expect("cached");
        assert_eq!(before, after, "a fresh cache entry must not be re-probed");
    }
}
