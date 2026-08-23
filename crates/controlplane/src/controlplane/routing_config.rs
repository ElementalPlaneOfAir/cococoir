// SPDX-License-Identifier: AGPL-3.0-or-later
//! The edge's live routing table: which customer `/128` maps to which
//! WireGuard peer.
//!
//! This is the in-process source of truth for the forwarder's listener
//! set. The control plane writes here at signup/delete; the forwarder
//! reconciles its live listeners against this table (bind on entry,
//! close on removal). One process owns one table — `main()` builds it
//! and hands `&RoutingTable` to both halves. No global: library code
//! takes the table as a parameter, so tests construct their own.
//!
//! The table is NOT the durable store — Redis is. On boot the control
//! plane rehydrates the table from Redis before the forwarder starts
//! accepting traffic (see `proposal.md` "Strongest objection": the
//! reconcile-on-boot is obligatory).

use std::net::Ipv6Addr;

use dashmap::DashMap;
use serde::{Deserialize, Serialize};

/// A customer route: the customer's `/128` on the edge, and the WG
/// peer (tunnel address + public key) the forwarder sends its traffic
/// to. Stored in the table keyed by the `/128`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WgPeer {
    /// The customer's WG tunnel address inside wg0 (e.g. `10.10.0.2`).
    pub wg_ip: String,
    /// The customer's WireGuard public key (added to wg0 via `wg set`).
    pub wg_public_key: String,
}

/// Live routing table: `/128` → WG peer. `DashMap` so the control
/// plane (HTTP handlers) and the forwarder (reconcile loop) can
/// access entries concurrently without a single writer lock.
#[derive(Debug)]
pub struct RoutingTable {
    routes: DashMap<Ipv6Addr, WgPeer>,
}

impl RoutingTable {
    /// An empty table. `main()` builds this and passes `&` to the
    /// control plane and forwarder.
    pub fn new() -> Self {
        Self {
            routes: DashMap::new(),
        }
    }

    /// Insert or replace the route for a customer `/128`.
    pub fn upsert(&self, ipv6: Ipv6Addr, peer: WgPeer) {
        self.routes.insert(ipv6, peer);
    }

    /// Remove the route for a customer `/128`. Returns the removed
    /// peer, or `None` if the address had no route.
    pub fn remove(&self, ipv6: &Ipv6Addr) -> Option<WgPeer> {
        self.routes.remove(ipv6).map(|(_, peer)| peer)
    }

    /// Look up the WG peer for a customer `/128`.
    pub fn get(&self, ipv6: &Ipv6Addr) -> Option<WgPeer> {
        self.routes.get(ipv6).map(|entry| entry.value().clone())
    }

    /// All routes. Order is unspecified (DashMap); callers that need
    /// determinism sort by address.
    pub fn entries(&self) -> Vec<(Ipv6Addr, WgPeer)> {
        self.routes
            .iter()
            .map(|entry| (*entry.key(), entry.value().clone()))
            .collect()
    }

    /// Number of routes.
    pub fn len(&self) -> usize {
        self.routes.len()
    }
}

impl Default for RoutingTable {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer(wg_ip: &str) -> WgPeer {
        WgPeer {
            wg_ip: wg_ip.to_string(),
            wg_public_key: "pubkey".to_string(),
        }
    }

    #[test]
    fn empty_table_has_no_routes() {
        let table = RoutingTable::new();
        assert_eq!(table.len(), 0);
        assert!(table.entries().is_empty());
    }

    #[test]
    fn upsert_then_get_returns_peer() {
        let table = RoutingTable::new();
        let ip = "2a01:4f8:c17:1::2".parse().unwrap();
        table.upsert(ip, peer("10.10.0.2"));
        assert_eq!(table.get(&ip).unwrap().wg_ip, "10.10.0.2");
        assert_eq!(table.len(), 1);
    }

    #[test]
    fn upsert_same_address_replaces() {
        let table = RoutingTable::new();
        let ip = "2a01:4f8:c17:1::2".parse().unwrap();
        table.upsert(ip, peer("10.10.0.2"));
        table.upsert(ip, peer("10.10.0.3"));
        assert_eq!(table.get(&ip).unwrap().wg_ip, "10.10.0.3");
        assert_eq!(table.len(), 1);
    }

    #[test]
    fn remove_returns_peer_and_clears_entry() {
        let table = RoutingTable::new();
        let ip = "2a01:4f8:c17:1::2".parse().unwrap();
        table.upsert(ip, peer("10.10.0.2"));
        let removed = table.remove(&ip);
        assert_eq!(removed.unwrap().wg_ip, "10.10.0.2");
        assert!(table.get(&ip).is_none());
        assert_eq!(table.len(), 0);
    }

    #[test]
    fn remove_missing_returns_none() {
        let table = RoutingTable::new();
        let ip = "2a01:4f8:c17:1::2".parse().unwrap();
        assert!(table.remove(&ip).is_none());
    }

    #[test]
    fn get_missing_returns_none() {
        let table = RoutingTable::new();
        let ip = "2a01:4f8:c17:1::2".parse().unwrap();
        assert!(table.get(&ip).is_none());
    }

    #[test]
    fn entries_covers_all_routes() {
        let table = RoutingTable::new();
        let a: Ipv6Addr = "2a01:4f8:c17:1::2".parse().unwrap();
        let b: Ipv6Addr = "2a01:4f8:c17:1::3".parse().unwrap();
        table.upsert(a, peer("10.10.0.2"));
        table.upsert(b, peer("10.10.0.3"));
        let mut ips: Vec<Ipv6Addr> = table.entries().into_iter().map(|(ip, _)| ip).collect();
        ips.sort();
        assert_eq!(ips, vec![a, b]);
    }
}
