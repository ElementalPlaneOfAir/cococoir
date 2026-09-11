// SPDX-License-Identifier: AGPL-3.0-or-later
//! Edge-pair high availability (ADR-029): the hot-hot reconcile.
//!
//! Both nodes point at ONE shared external Redis (the store URL is the
//! pair's shared coordinate), so `SET NX` on `fortress:edge:lease` is
//! genuinely mutually exclusive: the lease arbitrates boot (first to
//! acquire is active), detects death (an unrenewed lease expires after
//! the TTL), and names the driver of float correction — the lease holder
//! moves any drifted float back onto its own server where the peer's
//! despair about the lease's refusal ("never grabs back") instead of the
//! lease's owner. A leader that cannot reach the Hetzner API self-fences:
//! it releases the lease so the peer can take over immediately instead
//! of waiting out the TTL (the R4 fast path).

use crate::controlplane::ControlPlane;
use crate::controlplane::ControlPlaneError;
use crate::controlplane::float::FloatApiClient;
use crate::controlplane::lease::{LeaderLease, LEASE_TTL_SECS};

/// The outcome of one HA reconcile pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HaRole {
    /// This node holds the lease and the floats: the active edge.
    Active,
    /// The peer holds the lease (or no decision was safe): standby.
    Standby,
}

/// Per-node HA identity. Provision values: this node's id and Hetzner
/// server id — the float `assign` target. The peer needs no coordinates
/// of ours shared: the store is the shared coordinate. Requires the
/// Hetzner API token; the float client is the repair tool.
#[derive(Debug, Clone)]
pub struct HaConfig {
    /// This node's identity (e.g. "edge-a") — the lease's holder id.
    pub node_id: String,
    /// This node's Hetzner server id.
    pub server_id: u64,
    /// Lease TTL in seconds — the failure-detection window. Defaults to
    /// [`LEASE_TTL_SECS`]; tests shorten it so expiry is fast.
    pub lease_ttl_secs: u64,
}

impl HaConfig {
    /// Production defaults: the lease heartbeat from [`LEASE_TTL_SECS`].
    pub fn new(node_id: &str, server_id: u64) -> Self {
        Self {
            node_id: node_id.to_string(),
            server_id,
            lease_ttl_secs: LEASE_TTL_SECS,
        }
    }
}

/// The hot-hot reconcile driver: drives the control plane's Redis
/// connection (the shared store) against the float client and this
/// node's identity.
pub struct EdgeHa {
    cp: &'static ControlPlane,
    float: &'static dyn FloatApiClient,
    config: HaConfig,
}

impl EdgeHa {
    /// `cp` provides the store connection; `float` moves the floats;
    /// `config` is this node's identity.
    pub fn new(cp: &'static ControlPlane, float: &'static dyn FloatApiClient, config: HaConfig) -> Self {
        assert!(!config.node_id.is_empty(), "a node needs an id");
        assert!(config.server_id != 0, "a node needs a Hetzner server id");
        assert!(config.lease_ttl_secs > 0, "the lease ttl must be positive");
        Self { cp, float, config }
    }

    /// One reconcile pass. Returns the node's role after the pass.
    ///
    /// The lease is read FIRST and is the only authority: the float API
    /// is touched by the lease holder alone (one driver per pass, not
    /// two — a 2s poll from both nodes would spend the Hetzner API's
    /// rate budget), and a holder whose float inventory cannot be read
    /// fences.
    pub async fn reconcile_once(&self) -> Result<HaRole, ControlPlaneError> {
        let mut conn = self.cp.conn().await?;
        let lease = LeaderLease::new(&self.config.node_id);
        let owner_is_me = lease
            .is_held_by(&mut conn, &self.config.node_id)
            .await?;

        if !owner_is_me {
            // Held by the peer (alive — it is renewing) or expired-but-
            // contested: claim it. A fresh or dead-pair boot races here;
            // SET NX picks exactly one winner.
            let acquired = lease
                .try_acquire(&mut conn, self.config.lease_ttl_secs)
                .await?;
            return Ok(if acquired {
                self.correct_floats().await?;
                HaRole::Active
            } else {
                HaRole::Standby
            });
        }

        // I hold the lease: renew, then verify + correct float drift —
        // the lease holder is the driver; the peer never re-assigns.
        if !lease.renew(&mut conn, self.config.lease_ttl_secs).await? {
            // The lease expired and the peer took it between ticks.
            // Never grab back: stand down and let the winner converge.
            tracing::warn!(node = %self.config.node_id, "ha: lease lost mid-reconcile; standing down (never re-assigns)");
            return Ok(HaRole::Standby);
        }
        match self.correct_floats().await {
            Ok(()) => Ok(HaRole::Active),
            Err(ControlPlaneError::Float(err)) => {
                // Self-fence (the R4 fast path): I cannot verify float
                // ownership and cannot move floats back if the peer
                // takes over, so release leadership now. Owner-guarded
                // release cannot drop a lease the peer acquired. A
                // transient API blip costs one controlled failover.
                let released = lease.release(&mut conn).await?;
                tracing::warn!(err = %err, released, "ha: float api unreachable; self-fencing");
                Ok(HaRole::Standby)
            }
            Err(err) => Err(err),
        }
    }

    /// Move every float not assigned to this node onto it: the lease
    /// holder's drift correction, and the takeover's float seizure.
    async fn correct_floats(&self) -> Result<(), ControlPlaneError> {
        let floats = self.float.list().await?;
        for f in &floats {
            if f.server != Some(self.config.server_id) {
                tracing::info!(float_id = f.id, from = ?f.server, to = self.config.server_id, "ha: moving float");
                self.float
                    .assign(f.id, self.config.server_id)
                    .await
                    .map_err(ControlPlaneError::Float)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use crate::controlplane::dns::MockDnsApiClient;
    use crate::controlplane::float::{HetznerFloatingIp, MockFloatApiClient};
    use crate::Subnet64;
    use crate::WgSubnet;
    use crate::controlplane::lease::LEASE_KEY;
    use crate::controlplane::wg::MockWgClient;

    fn redis_url() -> Option<String> {
        match std::env::var("REDIS_URL") {
            Ok(url) if !url.is_empty() => Some(url),
            _ => {
                eprintln!("skipping: REDIS_URL not set");
                None
            }
        }
    }

    /// Cases mutate one shared lease key on the live test store; running
    /// them in parallel would fights each case's setup/teardown.
    static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// A fresh node harness on the live (test-gated) store: its own
    /// leaked control plane + float mock. The lease key is cleared so
    /// cases start from a free lease; the lease holds a TTL, so a
    /// mid-case takeover leaves no residue beyond `ttl_secs`.
    async fn setup(
        node_id: &str,
        server_id: u64,
    ) -> Option<(EdgeHa, &'static MockFloatApiClient, redis::aio::ConnectionManager)> {
        let url = redis_url()?;
        let mut conn = live_conn(&url).await;
        let _: i64 = redis::cmd("DEL").arg(LEASE_KEY).query_async(&mut conn).await.expect("del lease key");
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").expect("test subnet");
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").expect("test wg subnet");
        let cp: &'static ControlPlane = Box::leak(Box::new(
            ControlPlane::with_deps(
                &url,
                subnet,
                wg_subnet,
                "example.net",
                "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=",
                wg,
                dns,
            )
            .expect("control plane connects"),
        ));
        let mock: &'static MockFloatApiClient = Box::leak(Box::new(MockFloatApiClient::new()));
        let driver = EdgeHa::new(cp, mock, HaConfig::new(node_id, server_id));
        Some((driver, mock, conn))
    }

    fn float_with_server(id: u64, server: Option<u64>) -> HetznerFloatingIp {
        HetznerFloatingIp {
            id,
            type_: "ipv4".to_string(),
            ip: "192.0.2.10".to_string(),
            network: None,
            server,
            name: format!("test-float-{id}"),
        }
    }

    /// Grab the lease for an arbitrary node id directly (simulating the
    /// peer's live claim).
    async fn hold_lease(conn: &mut redis::aio::ConnectionManager, node_id: &str, ttl: u64) {
        let peer = LeaderLease::with_key(LEASE_KEY, node_id);
        assert!(peer.try_acquire(conn, ttl).await.expect("peer acquire"));
    }

    async fn lease_owner(conn: &mut redis::aio::ConnectionManager) -> Option<String> {
        LeaderLease::with_key(LEASE_KEY, "unused").owner(conn).await.expect("owner")
    }

    #[tokio::test]
    async fn takeover_acquires_lease_and_moves_floats() {
        let _lock = TEST_LOCK.lock().await;
        let Some((driver, mock, mut _conn)) = setup("a", 111).await else { return; };
        // Fresh pair: floats sit on the DEAD or missing peer; lease free.
        mock.floats.lock().unwrap().push(float_with_server(1, Some(999)));
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Active);
        assert_eq!(*mock.assigns.lock().unwrap(), vec![(1, 111)]);
    }

    #[tokio::test]
    async fn peer_holding_lease_means_standby_and_never_grabs_back() {
        let _lock = TEST_LOCK.lock().await;
        let Some((driver, mock, conn)) = setup("a", 111).await else { return; };
        hold_lease(&mut conn.clone(), "edge-b", 8).await;
        // Even when the floats are pointed at THIS node, the lease holder
        // is the driver: this node stands down without re-assigning.
        mock.floats.lock().unwrap().push(float_with_server(1, Some(111)));
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Standby);
        assert!(mock.assigns.lock().unwrap().is_empty());
        // A second pass stays standby (the peer renews; we never fight).
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Standby);
        assert!(mock.assigns.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn api_failure_self_fences_a_leader() {
        let _lock = TEST_LOCK.lock().await;
        let Some((driver, mock, mut conn)) = setup("a", 111).await else { return; };
        hold_lease(&mut conn.clone(), "a", 8).await;
        *mock.list_fails.lock().unwrap() = true;
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Standby);
        // The fence RELEASED the leadership: the peer can take over now.
        assert!(lease_owner(&mut conn).await.is_none());
        assert!(mock.assigns.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn active_node_corrects_float_drift() {
        let _lock = TEST_LOCK.lock().await;
        let Some((driver, mock, conn)) = setup("a", 111).await else { return; };
        hold_lease(&mut conn.clone(), "a", 8).await;
        // Two floats, two failures to converge: unassigned + peer-held.
        mock.floats
            .lock()
            .unwrap()
            .extend([float_with_server(1, None), float_with_server(2, Some(999))]);
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Active);
        let mut assigns = mock.assigns.lock().unwrap().clone();
        assigns.sort();
        assert_eq!(assigns, vec![(1, 111), (2, 111)]);
    }

    #[tokio::test]
    async fn lease_lost_mid_reconcile_stands_down_without_fighting() {
        let _lock = TEST_LOCK.lock().await;
        let Some((driver, mock, conn)) = setup("a", 111).await else { return; };
        hold_lease(&mut conn.clone(), "a", 8).await;
        // The lease flips to the peer between our reads: a wedged-
        // revival scenario. This node must stand down, not re-assign.
        let stolen = LeaderLease::with_key(LEASE_KEY, "edge-b");
        let _: i64 = redis::cmd("DEL").arg(LEASE_KEY).query_async(&mut conn.clone()).await.expect("del");
        assert!(stolen.try_acquire(&mut conn.clone().clone(), 8).await.expect("steal"));
        // Floats still pointed at us — the temptation. Standby anyway.
        mock.floats.lock().unwrap().push(float_with_server(1, Some(111)));
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Standby);
        assert!(mock.assigns.lock().unwrap().is_empty());
    }


    #[tokio::test]
    async fn expired_lease_takeover_meets_the_rto_budget() {
        let _lock = TEST_LOCK.lock().await;
        // RTO = detection (lease TTL 1s in test) + one tick + float move.
        // Production budget: TTL 8 + move <= 5 = under 15s (AC).
        let Some((mut driver, mock, conn)) = setup("b", 222).await else { return; };
        hold_lease(&mut conn.clone(), "edge-a", 1).await;
        mock.floats.lock().unwrap().push(float_with_server(1, Some(111)));
        driver.config.lease_ttl_secs = 1;
        tokio::time::sleep(Duration::from_millis(1300)).await;
        let started = std::time::Instant::now();
        let role = driver.reconcile_once().await.expect("reconciles");
        assert_eq!(role, HaRole::Active);
        assert_eq!(*mock.assigns.lock().unwrap(), vec![(1, 222)]);
        assert!(started.elapsed() < Duration::from_secs(15), "takeover over budget");
    }

    async fn live_conn(url: &str) -> redis::aio::ConnectionManager {
        let client = redis::Client::open(url).expect("redis url opens");
        redis::aio::ConnectionManager::new(client)
            .await
            .expect("redis connects")
    }
}
