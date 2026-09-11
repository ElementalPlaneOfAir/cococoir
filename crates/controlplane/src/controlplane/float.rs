// SPDX-License-Identifier: AGPL-3.0-or-later
//! Hetzner Floating IP provisioning — the edge's IP-mobility primitive.
//!
//! ADR-029: customer `/128`s live on a cluster-owned Floating IPv6 /64
//! and the WG dial-out endpoint + control-plane Caddy on a shared
//! Floating IPv4 /32. Both are *movable* between servers in the same
//! network zone, which is what makes failover a float reassignment
//! instead of a DNS rewrite. This module is the write client for those
//! floats — the same Cloud API (and the same Bearer token) the DNS
//! module uses, deliberately mirroring its shape: a swappable trait, a
//! Hetzner implementation, a recording mock for tests, and tripwires
//! pinning the Cloud API wire shape.
//!
//! The float-to-server mapping is owned ABOVE this module: the reconcile
//! loop decides which node is active and calls assign/unassign here.
//! This client never decides policy; it only moves floats.

use std::sync::LazyLock;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::controlplane::secret::SECRETS;

/// Errors from Floating IP provisioning.
#[derive(Debug, Error)]
pub enum FloatError {
    #[error("float api: {0}")]
    Api(String),
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
}

/// The Hetzner Cloud API base URL — the same Cloud API (and Bearer
/// token) the DNS module uses; there is no separate floating-IP console
/// API to be deprecated into.
const HETZNER_BASE: &str = "https://api.hetzner.cloud/v1";

/// A Hetzner Floating IP resource. `network` is the routed subnet for
/// ipv6 floats (the /64 customers carve /128s from); ipv4 floats carry
/// only `ip`. `server` is the node the float is currently assigned to.
#[derive(Debug, Clone, Deserialize)]
pub struct HetznerFloatingIp {
    pub id: u64,
    #[serde(rename = "type")]
    pub type_: String,
    pub ip: String,
    #[serde(default)]
    pub network: Option<String>,
    pub server: Option<u64>,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Deserialize)]
struct FloatingIpsResponse {
    floating_ips: Vec<HetznerFloatingIp>,
}

#[derive(Debug, Deserialize)]
struct FloatingIpResponse {
    floating_ip: HetznerFloatingIp,
}

#[derive(Debug, Serialize)]
struct AssignBody {
    server: u64,
}

#[derive(Debug, Serialize)]
struct CreateBody {
    #[serde(rename = "type")]
    type_: String,
    name: String,
}

/// The float-movement client. One operation per call; idempotency is
/// the reconcile layer's job (it reads `list` and only moves drift).
#[async_trait]
pub trait FloatApiClient: Send + Sync {
    /// Assign (or reassign) the float to `server_id`. Hetzner moves the
    /// float from whatever server currently holds it.
    async fn assign(&self, float_id: u64, server_id: u64) -> Result<(), FloatError>;
    /// Remove the float from whatever server holds it. An unassigned
    /// float is not an error.
    async fn unassign(&self, float_id: u64) -> Result<(), FloatError>;
    /// Provision a new float of `type_` ("ipv4" or "ipv6"). The caller
    /// assigns it to a node immediately after. Used by the IPv4 SKU
    /// provisioning path (T6).
    async fn create(&self, type_: &str, name: &str) -> Result<HetznerFloatingIp, FloatError>;
    /// Delete the float. Stops its recurring monthly billing.
    async fn delete(&self, float_id: u64) -> Result<(), FloatError>;
    /// Inventory: every float with its current server assignment. The
    /// reconcile loop reads this to detect drift.
    async fn list(&self) -> Result<Vec<HetznerFloatingIp>, FloatError>;
}

/// The real client: talks to Hetzner's Cloud Floating IP API with the
/// same project token the DNS module uses. The http client is built on
/// first use, not construction, so pure-logic tests and the nix build
/// sandbox (no CA certs) never touch reqwest.
#[derive(Clone)]
pub struct HetznerFloat {
    token: String,
    http: std::sync::OnceLock<reqwest::Client>,
}

impl HetznerFloat {
    fn from_secrets() -> Self {
        Self::new(SECRETS.secrets.dns_token.clone())
    }

    /// Construct from explicit config — the test seam for
    /// [`HetznerFloat::from_secrets`].
    pub(crate) fn new(token: String) -> Self {
        Self {
            token,
            http: std::sync::OnceLock::new(),
        }
    }

    fn http(&self) -> &reqwest::Client {
        self.http.get_or_init(reqwest::Client::new)
    }

    async fn post_action(
        &self,
        float_id: u64,
        action: &str,
        body: impl Serialize,
    ) -> Result<(), FloatError> {
        self.http()
            .post(format!(
                "{HETZNER_BASE}/floating_ips/{float_id}/actions/{action}"
            ))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

#[async_trait]
impl FloatApiClient for HetznerFloat {
    async fn assign(&self, float_id: u64, server_id: u64) -> Result<(), FloatError> {
        self.post_action(float_id, "assign", AssignBody { server: server_id })
            .await
    }

    async fn unassign(&self, float_id: u64) -> Result<(), FloatError> {
        self.post_action(float_id, "unassign", serde_json::json!({}))
            .await
    }

    async fn create(&self, type_: &str, name: &str) -> Result<HetznerFloatingIp, FloatError> {
        let resp = self
            .http()
            .post(format!("{HETZNER_BASE}/floating_ips"))
            .bearer_auth(&self.token)
            .json(&CreateBody {
                type_: type_.to_string(),
                name: name.to_string(),
            })
            .send()
            .await?
            .error_for_status()?;
        let body: FloatingIpResponse = resp.json().await?;
        Ok(body.floating_ip)
    }

    async fn delete(&self, float_id: u64) -> Result<(), FloatError> {
        self.http()
            .delete(format!("{HETZNER_BASE}/floating_ips/{float_id}"))
            .bearer_auth(&self.token)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn list(&self) -> Result<Vec<HetznerFloatingIp>, FloatError> {
        let resp = self
            .http()
            .get(format!("{HETZNER_BASE}/floating_ips"))
            .bearer_auth(&self.token)
            .send()
            .await?
            .error_for_status()?;
        let body: FloatingIpsResponse = resp.json().await?;
        Ok(body.floating_ips)
    }
}

/// The process's float client, built once from the resolved secrets.
static FLOAT_CLIENT: LazyLock<HetznerFloat> = LazyLock::new(HetznerFloat::from_secrets);

/// The process's float-movement client. Panics only if the secrets
/// failed to resolve, which `init_globals` forces at boot first.
pub fn get_float_api() -> &'static dyn FloatApiClient {
    &*FLOAT_CLIENT
}

/// A test client that records calls instead of hitting Hetzner.
#[derive(Debug, Default)]
pub struct MockFloatApiClient {
    pub assigns: std::sync::Mutex<Vec<(u64, u64)>>,
    pub unassigns: std::sync::Mutex<Vec<u64>>,
    pub creates: std::sync::Mutex<Vec<(String, String)>>,
    pub deletes: std::sync::Mutex<Vec<u64>>,
    pub floats: std::sync::Mutex<Vec<HetznerFloatingIp>>,
    pub next_id: std::sync::Mutex<u64>,
    pub list_fails: std::sync::Mutex<bool>,
}

impl MockFloatApiClient {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl FloatApiClient for MockFloatApiClient {
    async fn assign(&self, float_id: u64, server_id: u64) -> Result<(), FloatError> {
        self.assigns.lock().unwrap().push((float_id, server_id));
        Ok(())
    }

    async fn unassign(&self, float_id: u64) -> Result<(), FloatError> {
        self.unassigns.lock().unwrap().push(float_id);
        Ok(())
    }

    async fn create(&self, type_: &str, name: &str) -> Result<HetznerFloatingIp, FloatError> {
        self.creates.lock().unwrap().push((type_.to_string(), name.to_string()));
        let mut next = self.next_id.lock().unwrap();
        *next += 1;
        let id = *next;
        let ip = match type_ {
            "ipv4" => "192.0.2.10".to_string(),
            _ => "2001:db8:1::10".to_string(),
        };
        let float = HetznerFloatingIp {
            id,
            type_: type_.to_string(),
            ip,
            network: if type_ == "ipv6" {
                Some("2001:db8:1::/64".to_string())
            } else {
                None
            },
            server: None,
            name: name.to_string(),
        };
        self.floats.lock().unwrap().push(float.clone());
        Ok(float)
    }

    async fn delete(&self, float_id: u64) -> Result<(), FloatError> {
        self.deletes.lock().unwrap().push(float_id);
        Ok(())
    }

    async fn list(&self) -> Result<Vec<HetznerFloatingIp>, FloatError> {
        if *self.list_fails.lock().unwrap() {
            return Err(FloatError::Api("injected failure".to_string()));
        }
        Ok(self.floats.lock().unwrap().clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hetzner_base_is_cloud_api() {
        // Same Cloud API + Bearer token as the DNS module; floats were
        // never on the deprecated DNS Console API.
        assert_eq!(HETZNER_BASE, "https://api.hetzner.cloud/v1");
    }

    #[test]
    fn list_response_deserializes_cloud_api_shape() {
        let json = r#"{
            "floating_ips": [
                {
                    "id": 4711,
                    "type": "ipv6",
                    "ip": "2a01:4f9:1:2::1",
                    "network": "2a01:4f9:1:2::/64",
                    "server": 42,
                    "name": "cluster-v6",
                    "description": "",
                    "created": "2016-01-30T23:50:00+00:00",
                    "blocked": false,
                    "home_location": {"id": 1, "name": "hel1"},
                    "protection": {"delete": false},
                    "labels": {}
                },
                {
                    "id": 4712,
                    "type": "ipv4",
                    "ip": "1.2.3.4",
                    "server": null,
                    "name": "wg-endpoint",
                    "description": "",
                    "created": "2016-01-30T23:50:00+00:00",
                    "blocked": false,
                    "home_location": {"id": 1, "name": "hel1"},
                    "protection": {"delete": false},
                    "labels": {}
                }
            ]
        }"#;
        let parsed: FloatingIpsResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.floating_ips.len(), 2);
        let v6 = &parsed.floating_ips[0];
        assert_eq!(v6.type_, "ipv6");
        assert_eq!(v6.network.as_deref(), Some("2a01:4f9:1:2::/64"));
        assert_eq!(v6.server, Some(42));
        let v4 = &parsed.floating_ips[1];
        assert_eq!(v4.type_, "ipv4");
        assert_eq!(v4.network, None);
        assert_eq!(v4.server, None);
    }

    #[test]
    fn assign_body_serializes_server() {
        let body = AssignBody { server: 7 };
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(json, serde_json::json!({ "server": 7 }));
    }

    #[test]
    fn create_body_serializes_type_and_name() {
        let body = CreateBody {
            type_: "ipv4".to_string(),
            name: "customer-alice".to_string(),
        };
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "type": "ipv4", "name": "customer-alice" })
        );
    }

    #[test]
    fn create_response_deserializes_cloud_api_shape() {
        let json = r#"{
            "floating_ip": {
                "id": 4713,
                "type": "ipv4",
                "ip": "1.2.3.5",
                "server": null,
                "name": "customer-alice",
                "description": "",
                "created": "2016-01-30T23:50:00+00:00",
                "blocked": false,
                "home_location": {"id": 1, "name": "hil1"},
                "protection": {"delete": false},
                "labels": {}
            }
        }"#;
        let parsed: FloatingIpResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.floating_ip.id, 4713);
        assert_eq!(parsed.floating_ip.type_, "ipv4");
        assert_eq!(parsed.floating_ip.ip, "1.2.3.5");
        assert_eq!(parsed.floating_ip.server, None);
    }

    #[tokio::test]
    async fn mock_records_float_movements() {
        let mock = MockFloatApiClient::new();
        mock.assign(4711, 1).await.unwrap();
        mock.assign(4712, 1).await.unwrap();
        mock.unassign(4711).await.unwrap();
        mock.delete(4712).await.unwrap();
        assert_eq!(*mock.assigns.lock().unwrap(), vec![(4711, 1), (4712, 1)]);
        assert_eq!(*mock.unassigns.lock().unwrap(), vec![4711]);
        assert_eq!(*mock.deletes.lock().unwrap(), vec![4712]);
    }

    #[tokio::test]
    async fn mock_create_provisions_unassigned_float() {
        let mock = MockFloatApiClient::new();
        let float = mock.create("ipv4", "customer-alice").await.unwrap();
        assert_eq!(float.type_, "ipv4");
        assert_eq!(float.server, None);
        assert_eq!(float.name, "customer-alice");
        assert_eq!(
            *mock.creates.lock().unwrap(),
            vec![("ipv4".to_string(), "customer-alice".to_string())]
        );
        assert_eq!(mock.list().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn mock_list_returns_inventory() {
        let mock = MockFloatApiClient::new();
        mock.floats.lock().unwrap().push(HetznerFloatingIp {
            id: 4711,
            type_: "ipv6".to_string(),
            ip: "2a01:4f9:1:2::1".to_string(),
            network: Some("2a01:4f9:1:2::/64".to_string()),
            server: Some(42),
            name: "cluster-v6".to_string(),
        });
        let list = mock.list().await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].server, Some(42));
        assert_eq!(list[0].network.as_deref(), Some("2a01:4f9:1:2::/64"));
    }
}