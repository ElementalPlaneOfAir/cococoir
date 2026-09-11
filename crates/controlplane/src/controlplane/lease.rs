// SPDX-License-Identifier: AGPL-3.0-or-later
//! The edge-pair leader lease (ADR-029).
//!
//! One key, one holder: `fortress:edge:lease`. The lease is the
//! heartbeat the standby observes through Redis replication; when the
//! primary dies the replicated copy stops renewing and expires after the
//! TTL, which is the standby's promote signal. Every write is
//! owner-guarded so a wedged primary can never resurrect a lease its
//! peer has taken over (the R4 flapping path): renew and release both
//! compare the stored owner against the caller before touching the key.

use redis::AsyncCommands;

/// The leader-lease key (ADR-029). Lives in the primary's Redis and is
/// observed by the standby through replication.
pub const LEASE_KEY: &str = "fortress:edge:lease";

/// Lease TTL: how long the key lives without a renewal. This IS the
/// failure-detection window — the standby promotes once the replicated
/// copy expires — so it bounds the RTO budget (detect ≈ TTL + one poll).
pub const LEASE_TTL_SECS: u64 = 8;

/// The active node renews the lease every `LEASE_RENEW_SECS`. Several
/// renewals fit inside the TTL, so a single missed renewal never trips
/// failover.
pub const LEASE_RENEW_SECS: u64 = 2;

/// A node's claim on the edge-pair lease. `node_id` names the holder
/// (a per-node provision value, e.g. "edge-a"); every write compares
/// against it, so no operation can clobber another node's lease.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LeaderLease {
    key: String,
    node_id: String,
}

impl LeaderLease {
    /// The lease for `node_id` on the default key.
    pub fn new(node_id: &str) -> Self {
        assert!(!node_id.is_empty(), "a lease needs a node id");
        Self::with_key(LEASE_KEY, node_id)
    }

    /// A lease on a caller-chosen key — tests isolate leases per case so
    /// they never contend over one shared key.
    pub fn with_key(key: &str, node_id: &str) -> Self {
        assert!(!node_id.is_empty(), "a lease needs a node id");
        assert!(!key.is_empty(), "a lease needs a key");
        Self {
            key: key.to_string(),
            node_id: node_id.to_string(),
        }
    }

    /// The key this lease lives on (tests clean up after themselves).
    pub fn key(&self) -> &str {
        &self.key
    }

    /// Acquire the lease: `SET key node NX EX ttl`. Fails (false) if any
    /// other node currently holds it.
    pub async fn try_acquire(
        &self,
        conn: &mut redis::aio::ConnectionManager,
        ttl_secs: u64,
    ) -> Result<bool, redis::RedisError> {
        if ttl_secs == 0 {
            return Err(redis::RedisError::from((
                redis::ErrorKind::ResponseError,
                "lease ttl must be greater than zero",
            )));
        }
        let set: Option<String> = redis::cmd("SET")
            .arg(&self.key)
            .arg(&self.node_id)
            .arg("NX")
            .arg("EX")
            .arg(ttl_secs)
            .query_async(conn)
            .await?;
        Ok(set.is_some())
    }

    /// Renew the lease, owner-guarded: the key is refreshed only if this
    /// node still holds it. Refuses to touch a lease held by anyone else
    /// — a wedged primary cannot resurrect a lease it lost (the R4
    /// flapping path).
    pub async fn renew(
        &self,
        conn: &mut redis::aio::ConnectionManager,
        ttl_secs: u64,
    ) -> Result<bool, redis::RedisError> {
        let owner: Option<String> = conn.get(&self.key).await?;
        if owner.as_deref() != Some(self.node_id.as_str()) {
            return Ok(false);
        }
        let set: Option<String> = redis::cmd("SET")
            .arg(&self.key)
            .arg(&self.node_id)
            .arg("XX")
            .arg("EX")
            .arg(ttl_secs)
            .query_async(conn)
            .await?;
        Ok(set.is_some())
    }

    /// Release the lease, owner-guarded: `DEL` only if this node still
    /// holds it. Returns whether the lease was actually removed.
    pub async fn release(
        &self,
        conn: &mut redis::aio::ConnectionManager,
    ) -> Result<bool, redis::RedisError> {
        let owner: Option<String> = conn.get(&self.key).await?;
        if owner.as_deref() != Some(self.node_id.as_str()) {
            return Ok(false);
        }
        let removed: i64 = conn.del(&self.key).await?;
        Ok(removed == 1)
    }

    /// The current holder, if any.
    pub async fn owner(
        &self,
        conn: &mut redis::aio::ConnectionManager,
    ) -> Result<Option<String>, redis::RedisError> {
        conn.get(&self.key).await
    }

    /// Whether `node_id` currently holds the lease.
    pub async fn is_held_by(
        &self,
        conn: &mut redis::aio::ConnectionManager,
        node_id: &str,
    ) -> Result<bool, redis::RedisError> {
        Ok(self.owner(conn).await?.as_deref() == Some(node_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn redis_url() -> Option<String> {
        match std::env::var("REDIS_URL") {
            Ok(url) if !url.is_empty() => Some(url),
            _ => {
                eprintln!("skipping: REDIS_URL not set");
                None
            }
        }
    }

    async fn live_conn(url: &str) -> redis::aio::ConnectionManager {
        let client = redis::Client::open(url).expect("redis url opens");
        redis::aio::ConnectionManager::new(client)
            .await
            .expect("redis connects")
    }

    async fn reset_key(url: &str, key: &str) {
        let mut c = live_conn(url).await;
        let _: i64 = redis::cmd("DEL").arg(key).query_async(&mut c).await.expect("del");
    }

    fn test_key(label: &str) -> String {
        format!("{LEASE_KEY}:test:{label}")
    }

    #[tokio::test]
    async fn lease_acquire_renew_release_round_trip() {
        let Some(url) = redis_url() else {
            return;
        };
        let key = test_key("round_trip");
        reset_key(&url, &key).await;
        let mut conn = live_conn(&url).await;
        let lease = LeaderLease::with_key(&key, "edge-a");

        assert!(lease.try_acquire(&mut conn, 8).await.unwrap());
        assert!(lease.is_held_by(&mut conn, "edge-a").await.unwrap());
        assert!(!lease.is_held_by(&mut conn, "edge-b").await.unwrap());
        assert!(lease.renew(&mut conn, 8).await.unwrap());
        assert_eq!(lease.owner(&mut conn).await.unwrap().as_deref(), Some("edge-a"));
        assert!(lease.release(&mut conn).await.unwrap());
        assert!(!lease.is_held_by(&mut conn, "edge-a").await.unwrap());
    }

    #[tokio::test]
    async fn lease_acquire_fails_while_held() {
        let Some(url) = redis_url() else {
            return;
        };
        let key = test_key("acquire_fails");
        reset_key(&url, &key).await;
        let mut conn = live_conn(&url).await;
        let a = LeaderLease::with_key(&key, "edge-a");
        let b = LeaderLease::with_key(&key, "edge-b");

        assert!(a.try_acquire(&mut conn, 8).await.unwrap());
        assert!(!b.try_acquire(&mut conn, 8).await.unwrap());
        assert!(a.release(&mut conn).await.unwrap());
        assert!(b.try_acquire(&mut conn, 8).await.unwrap());
    }

    #[tokio::test]
    async fn lease_expires_after_ttl_without_renewal() {
        let Some(url) = redis_url() else {
            return;
        };
        let key = test_key("expires");
        reset_key(&url, &key).await;
        let mut conn = live_conn(&url).await;
        let lease = LeaderLease::with_key(&key, "edge-a");

        assert!(lease.try_acquire(&mut conn, 1).await.unwrap());
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        assert!(lease.owner(&mut conn).await.unwrap().is_none());
        // After expiry another node can acquire.
        let b = LeaderLease::with_key(&key, "edge-b");
        assert!(b.try_acquire(&mut conn, 8).await.unwrap());
    }

    #[tokio::test]
    async fn wrong_owner_renew_refused() {
        // The R4 assertion: a wedged primary (edge-a's lease was lost to
        // edge-b) cannot resurrect it by renewing.
        let Some(url) = redis_url() else {
            return;
        };
        let key = test_key("wrong_owner_renew");
        reset_key(&url, &key).await;
        let mut conn = live_conn(&url).await;
        let a = LeaderLease::with_key(&key, "edge-a");
        let b = LeaderLease::with_key(&key, "edge-b");

        assert!(a.try_acquire(&mut conn, 8).await.unwrap());
        assert!(!b.renew(&mut conn, 8).await.unwrap());
        assert!(a.renew(&mut conn, 8).await.unwrap());
        assert!(a.release(&mut conn).await.unwrap());
        assert!(b.try_acquire(&mut conn, 8).await.unwrap());
        assert!(!a.renew(&mut conn, 8).await.unwrap());
    }

    #[tokio::test]
    async fn wrong_owner_release_refused() {
        let Some(url) = redis_url() else {
            return;
        };
        let key = test_key("wrong_owner_release");
        reset_key(&url, &key).await;
        let mut conn = live_conn(&url).await;
        let a = LeaderLease::with_key(&key, "edge-a");
        let b = LeaderLease::with_key(&key, "edge-b");

        assert!(a.try_acquire(&mut conn, 8).await.unwrap());
        assert!(!b.release(&mut conn).await.unwrap());
        assert!(a.is_held_by(&mut conn, "edge-a").await.unwrap());
        assert!(a.release(&mut conn).await.unwrap());
    }

    #[tokio::test]
    async fn renew_does_not_extend_a_key_that_was_deleted() {
        let Some(url) = redis_url() else {
            return;
        };
        let key = test_key("renew_absent");
        reset_key(&url, &key).await;
        let mut conn = live_conn(&url).await;
        let a = LeaderLease::with_key(&key, "edge-a");

        assert!(!a.renew(&mut conn, 8).await.unwrap());
        assert!(!a.release(&mut conn).await.unwrap());
    }
}