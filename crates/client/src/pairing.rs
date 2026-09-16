// SPDX-License-Identifier: AGPL-3.0-or-later
//! Invite-based machine enrollment — the box side (T8).
//!
//! A box that ships without a tunnel config joins by dialing an invite
//! URL (`https://{domain}/a/{code}`): it posts its WG public key to the
//! edge (`POST /api/invites/{code}/begin`), polls until the owner
//! approves, then persists the assigned route as `tunnel.json` and its
//! device token (0600) — the token authorizes pubkey rotation later
//! without any human. Boot prefers persisted state: an enrolled box
//! never re-enrolls, and a box with a Nix-wired static tunnel skips
//! enrollment entirely.
//!
//! The edge API is behind the [`EdgeClient`] trait (async-trait) so
//! tests inject a mock — no live network in L0 — and so the future
//! dashboard-driven enrollment reuses the same seam.
//!
//! The forwarder's forwards reference the tunnel IP via the
//! `{tunnel_ip}` placeholder in `dest_addr`; enrollment assigns the IP,
//! so substitution happens at boot once the tunnel state is known
//! ([`substitute_tunnel_ip`]).

use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::tunnel::{default_iface, default_prefix, TunnelConfig};

/// The persisted tunnel state (written after enrollment, read at boot).
pub fn tunnel_state_path() -> std::path::PathBuf {
    PathBuf::from("/var/lib/fortress/tunnel.json")
}

/// The persisted device token (0600) — the rotation credential.
pub fn device_token_path() -> std::path::PathBuf {
    PathBuf::from("/var/lib/fortress/device-token")
}

/// The per-box invite configuration. Sits beside (never with) a static
/// `tunnel` in the config file — the app rejects both at once, because
/// a box cannot be both Nix-wired and self-enrolling.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InviteConfig {
    /// The full invite URL the owner shared, e.g.
    /// `https://proletariat.tech/a/kowiqmz4xy`.
    pub invite_url: String,
    /// The edge's dial-out endpoint (static edge property), e.g.
    /// `62.238.111.21:51820`.
    pub edge_endpoint: String,
    /// The edge's tunnel range to route, e.g. `10.10.0.0/24`.
    pub edge_allowed_ips: String,
    #[serde(default = "default_iface")]
    pub iface: String,
    #[serde(default = "default_prefix")]
    pub prefix: u8,
    #[serde(default)]
    pub listen_port: u16,
}

impl InviteConfig {
    /// The edge's API base (scheme + host) and the invite code, parsed
    /// from the invite URL. Malformed URLs fail fast — a typo'd paste
    /// must not silently become a broken enrollment.
    pub fn parse(&self) -> Result<(String, String), EnrollError> {
        let rest = self
            .invite_url
            .strip_prefix("https://")
            .or_else(|| self.invite_url.strip_prefix("http://"))
            .ok_or_else(|| EnrollError::InviteUrl(self.invite_url.clone()))?;
        let (base, code) = match rest.split_once('/') {
            Some((host, path)) => (host, path.strip_prefix("a/").unwrap_or(path)),
            None => return Err(EnrollError::InviteUrl(self.invite_url.clone())),
        };
        if base.is_empty() || code.is_empty() || code.contains('/') {
            return Err(EnrollError::InviteUrl(self.invite_url.clone()));
        }
        Ok((format!("https://{base}"), code.to_string()))
    }
}

/// What the edge's poll returns (box-side view).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PollOutcome {
    /// `waiting` | `approved` | `denied`.
    pub status: String,
    /// The machine's assigned tunnel IP — present on `approved`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wg_ip: Option<String>,
    /// The device token — delivered exactly once with `approved`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_token: Option<String>,
}

/// Enrollment failure surface.
#[derive(Debug, Error)]
pub enum EnrollError {
    #[error("invalid invite URL: {0}")]
    InviteUrl(String),
    #[error("edge api: {0}")]
    Api(String),
    #[error("denied: the owner denied this machine's enrollment")]
    Denied,
    #[error("owner did not approve in time ({0} polls)")]
    TimedOut(u32),
    #[error("state persistence failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("assigned tunnel ip is missing from the approval payload")]
    NoTunnelIp,
}

/// The edge API seam. Box-side HTTP impl + test mocks.
#[async_trait]
pub trait EdgeClient: Send + Sync {
    async fn begin(&self, code: &str, public_key: &str) -> Result<PollOutcome, EnrollError>;
    async fn poll(&self, code: &str) -> Result<PollOutcome, EnrollError>;
    async fn edge_pubkey(&self) -> Result<String, EnrollError>;
    /// Rotate this machine's WG key on its existing route. The device
    /// token is the credential — no invite, no session, no AdminKey.
    async fn rotate(&self, device_token: &str, public_key: &str) -> Result<(), EnrollError>;
}

/// The HTTP edge client. Base is the invite URL's origin; everything
/// else derives from it.
pub struct HttpEdgeClient {
    http: reqwest::Client,
    base: String,
}

impl HttpEdgeClient {
    pub fn new(invite_url: &str) -> Result<Self, EnrollError> {
        let (base, _code) = (InviteConfig {
            invite_url: invite_url.to_string(),
            edge_endpoint: String::new(),
            edge_allowed_ips: String::new(),
            iface: String::new(),
            prefix: 24,
            listen_port: 0,
        })
        .parse()?;
        Ok(Self {
            http: reqwest::Client::new(),
            base,
        })
    }

    async fn post_json(
        &self,
        path: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, EnrollError> {
        let url = format!("{}{path}", self.base);
        let resp = self
            .http
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|err| EnrollError::Api(format!("{url}: {err}")))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|err| EnrollError::Api(format!("{url}: {err}")))?;
        if !status.is_success() {
            return Err(EnrollError::Api(format!("{url}: {status} {text}")));
        }
        serde_json::from_str(&text).map_err(|err| EnrollError::Api(format!("{url}: {err}")))
    }

    async fn get_json(&self, path: &str) -> Result<serde_json::Value, EnrollError> {
        let url = format!("{}{path}", self.base);
        let resp = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|err| EnrollError::Api(format!("{url}: {err}")))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|err| EnrollError::Api(format!("{url}: {err}")))?;
        if !status.is_success() {
            return Err(EnrollError::Api(format!("{url}: {status} {text}")));
        }
        serde_json::from_str(&text).map_err(|err| EnrollError::Api(format!("{url}: {err}")))
    }
}

fn poll_outcome(value: serde_json::Value) -> PollOutcome {
    PollOutcome {
        status: value
            .get("status")
            .and_then(|s| s.as_str())
            .unwrap_or_default()
            .to_string(),
        wg_ip: value
            .get("machine")
            .and_then(|m| m.get("wg_ip"))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        device_token: value
            .get("deviceToken")
            .and_then(|v| v.as_str())
            .map(str::to_string),
    }
}

#[async_trait]
impl EdgeClient for HttpEdgeClient {
    async fn begin(&self, code: &str, public_key: &str) -> Result<PollOutcome, EnrollError> {
        self.post_json(
            &format!("/api/invites/{code}/begin"),
            serde_json::json!({ "public_key": public_key }),
        )
        .await
        .map(poll_outcome)
    }

    async fn poll(&self, code: &str) -> Result<PollOutcome, EnrollError> {
        self.get_json(&format!("/api/invites/{code}/poll"))
            .await
            .map(poll_outcome)
    }

    async fn edge_pubkey(&self) -> Result<String, EnrollError> {
        let value = self.get_json("/api/wireguard/pubkey").await?;
        value
            .get("public_key")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| EnrollError::Api("pubkey response missing public_key".to_string()))
    }

    async fn rotate(&self, device_token: &str, public_key: &str) -> Result<(), EnrollError> {
        let url = format!("{}/api/device/register", self.base);
        let resp = self
            .http
            .post(&url)
            .json(&serde_json::json!({
                "device_token": device_token,
                "public_key": public_key,
            }))
            .send()
            .await
            .map_err(|err| EnrollError::Api(format!("{url}: {err}")))?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp
                .text()
                .await
                .unwrap_or_else(|_| "unreadable body".to_string());
            return Err(EnrollError::Api(format!("{url}: {status} {text}")));
        }
        Ok(())
    }
}

/// Parse the invite URL's edge base for a config that has only the URL.
pub fn edge_base(invite_url: &str) -> Result<String, EnrollError> {
    (InviteConfig {
        invite_url: invite_url.to_string(),
        edge_endpoint: String::new(),
        edge_allowed_ips: String::new(),
        iface: String::new(),
        prefix: 24,
        listen_port: 0,
    })
    .parse()
    .map(|(base, _)| base)
}

/// Enroll the box: begin → poll until approved → persist the tunnel
/// state + device token. Returns the tunnel config to bring wg0 up
/// with. `poll_interval` and `max_polls` are parameters (production:
/// 5s × ~10k = 30 days of waiting for the owner's approval; tests:
/// instant).
///
/// A previous enrollment is never repeated: check
/// [`persisted_tunnel_state`] BEFORE calling this.
pub async fn enroll(
    client: &dyn EdgeClient,
    cfg: &InviteConfig,
    key_path: &Path,
    tunnel_state_path: &Path,
    device_token_path: &Path,
    poll_interval: std::time::Duration,
    mut max_polls: u32,
) -> Result<TunnelConfig, EnrollError> {
    let (_base, code) = cfg.parse()?;
    let pubkey = crate::tunnel::ensure_keypair(key_path)
        .map_err(|err| EnrollError::Api(format!("keypair: {err}")))?;
    let begun = client.begin(&code, &pubkey).await?;
    if begun.status == "denied" {
        return Err(EnrollError::Denied);
    }
    let approved = loop {
        let poll = client.poll(&code).await?;
        match poll.status.as_str() {
            "approved" => break poll,
            "waiting" => {}
            "denied" => return Err(EnrollError::Denied),
            other => return Err(EnrollError::Api(format!("unknown poll status: {other}"))),
        }
        max_polls = max_polls
            .checked_sub(1)
            .ok_or(EnrollError::TimedOut(max_polls))?;
        tokio::time::sleep(poll_interval).await;
    };
    let wg_ip = approved
        .wg_ip
        .clone()
        .ok_or_else(|| EnrollError::Api("approved payload missing wg_ip".to_string()))?;
    let device_token = approved
        .device_token
        .clone()
        .ok_or_else(|| EnrollError::Api("approved payload missing device token".to_string()))?;
    let edge_pubkey = client.edge_pubkey().await?;
    let tunnel = TunnelConfig {
        iface: cfg.iface.clone(),
        ip: wg_ip,
        prefix: cfg.prefix,
        edge_pubkey,
        edge_endpoint: cfg.edge_endpoint.clone(),
        edge_allowed_ips: cfg.edge_allowed_ips.clone(),
        listen_port: cfg.listen_port,
    };
    persist_tunnel_state(tunnel_state_path, &tunnel)?;
    persist_device_token(device_token_path, &device_token)?;
    Ok(tunnel)
}

/// Write the tunnel state (read at every boot, so a reboot skips
/// enrollment even if the edge is unreachable).
pub fn persist_tunnel_state(path: &Path, tunnel: &TunnelConfig) -> Result<(), EnrollError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(tunnel)
        .map_err(|err| EnrollError::Io(std::io::Error::other(err.to_string())))?;
    std::fs::write(path, json)?;
    Ok(())
}

/// Persist the device token (0600) — the rotation credential.
pub fn persist_device_token(path: &Path, token: &str) -> Result<(), EnrollError> {
    assert!(!token.is_empty(), "device token must be non-empty");
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true).mode(0o600);
    use std::io::Write;
    opts.open(path)?.write_all(token.as_bytes())?;
    Ok(())
}

/// The persisted tunnel state, if any. Boot reads this BEFORE enrolling.
pub fn persisted_tunnel_state(path: &Path) -> Option<TunnelConfig> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// The persisted device token, if any.
pub fn persisted_device_token(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

/// Rotate the box's WG key on its existing route: the device token is
/// the credential. Used when the key file is regenerated (re-provision)
/// — the route, forwards, and DNS survive; only the peer key changes.
pub async fn rotate(
    client: &dyn EdgeClient,
    device_token_path: &Path,
    key_path: &Path,
) -> Result<(), EnrollError> {
    let token = persisted_device_token(device_token_path)
        .ok_or_else(|| EnrollError::Api("no persisted device token".to_string()))?;
    let pubkey = crate::tunnel::ensure_keypair(key_path)
        .map_err(|err| EnrollError::Api(format!("keypair: {err}")))?;
    client.rotate(&token, &pubkey).await
}

/// Replace the `{tunnel_ip}` placeholder in every forward's dest_addr
/// with the assigned tunnel IP. Enrollment assigns the IP at runtime;
/// the config can only reference it as a placeholder.
pub fn substitute_tunnel_ip(
    forwards: &[fortress_core::forwarder::Forward],
    tunnel: &TunnelConfig,
) -> Vec<fortress_core::forwarder::Forward> {
    forwards
        .iter()
        .map(|f| {
            let mut fwd = f.clone();
            if fwd.dest_addr.contains("{tunnel_ip}") {
                assert!(!tunnel.ip.is_empty(), "tunnel ip required for substitution");
                fwd.dest_addr = fwd.dest_addr.replace("{tunnel_ip}", &tunnel.ip);
            }
            fwd
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct MockEdge {
        begin_calls: Mutex<Vec<(String, String)>>,
        poll_calls: Mutex<Vec<String>>,
        rotated: Mutex<Vec<(String, String)>>,
        /// The scripted poll responses, popped in order.
        poll_script: Mutex<Vec<PollOutcome>>,
        edge_pubkey: String,
    }

    impl MockEdge {
        fn new(edge_pubkey: &str) -> Self {
            Self {
                begin_calls: Mutex::new(Vec::new()),
                poll_calls: Mutex::new(Vec::new()),
                rotated: Mutex::new(Vec::new()),
                poll_script: Mutex::new(Vec::new()),
                edge_pubkey: edge_pubkey.to_string(),
            }
        }

        fn script(&mut self, polls: Vec<PollOutcome>) {
            self.poll_script = Mutex::new(polls);
        }
    }

    fn waiting() -> PollOutcome {
        PollOutcome {
            status: "waiting".to_string(),
            wg_ip: None,
            device_token: None,
        }
    }

    fn approved() -> PollOutcome {
        PollOutcome {
            status: "approved".to_string(),
            wg_ip: Some("10.10.0.7".to_string()),
            device_token: Some("tok-123".to_string()),
        }
    }

    #[async_trait]
    impl EdgeClient for MockEdge {
        async fn begin(&self, code: &str, public_key: &str) -> Result<PollOutcome, EnrollError> {
            self.begin_calls
                .lock()
                .unwrap()
                .push((code.to_string(), public_key.to_string()));
            Ok(waiting())
        }

        async fn poll(&self, _code: &str) -> Result<PollOutcome, EnrollError> {
            self.poll_calls.lock().unwrap().push(_code.to_string());
            let mut script = self.poll_script.lock().unwrap();
            if script.is_empty() {
                return Ok(waiting());
            }
            Ok(script.remove(0))
        }

        async fn edge_pubkey(&self) -> Result<String, EnrollError> {
            Ok(self.edge_pubkey.clone())
        }

        async fn rotate(&self, device_token: &str, public_key: &str) -> Result<(), EnrollError> {
            self.rotated
                .lock()
                .unwrap()
                .push((device_token.to_string(), public_key.to_string()));
            Ok(())
        }
    }

    fn invite_config() -> InviteConfig {
        InviteConfig {
            invite_url: "https://proletariat.tech/a/kowiqmz4xy".to_string(),
            edge_endpoint: "62.238.111.21:51820".to_string(),
            edge_allowed_ips: "10.10.0.0/24".to_string(),
            iface: "wg0".to_string(),
            prefix: 24,
            listen_port: 0,
        }
    }

    #[test]
    fn invite_config_parse_extracts_base_and_code() {
        let (base, code) = invite_config().parse().unwrap();
        assert_eq!(base, "https://proletariat.tech");
        assert_eq!(code, "kowiqmz4xy");
        let bad = InviteConfig {
            invite_url: "ftp://proletariat.tech/a/x".to_string(),
            ..invite_config()
        };
        assert!(bad.parse().is_err());
        let no_code = InviteConfig {
            invite_url: "https://proletariat.tech/a/".to_string(),
            ..invite_config()
        };
        assert!(no_code.parse().is_err());
    }

    #[tokio::test]
    async fn enroll_polls_until_approved_and_persists_state() {
        let mut edge = MockEdge::new("edgEK="); // derive not required by the mock
        edge.script(vec![waiting(), waiting(), approved()]);
        let dir = tempfile::tempdir().unwrap();
        let key_path = dir.path().join("wg-private.key");
        let state_path = dir.path().join("tunnel.json");
        let token_path = dir.path().join("device-token");
        let tunnel = enroll(
            &edge,
            &invite_config(),
            &key_path,
            &state_path,
            &token_path,
            std::time::Duration::from_millis(1),
            10,
        )
        .await
        .expect("enroll");
        // The route came from the approval payload.
        assert_eq!(tunnel.ip, "10.10.0.7");
        assert_eq!(tunnel.edge_pubkey, "edgEK=");
        assert_eq!(tunnel.edge_endpoint, "62.238.111.21:51820");
        // The machine called begin exactly once with its pubkey.
        let begins = edge.begin_calls.lock().unwrap();
        assert_eq!(begins.len(), 1);
        assert_eq!(begins[0].0, "kowiqmz4xy");
        assert!(!begins[0].1.is_empty(), "pubkey sent");
        // State persisted: a reboot reads it back instead of re-enrolling.
        let persisted = persisted_tunnel_state(&state_path).expect("tunnel.json persisted");
        assert_eq!(persisted.ip, "10.10.0.7");
        let token = persisted_device_token(&token_path).expect("token persisted");
        assert_eq!(token, "tok-123");
        // 0600 token.
        use std::os::unix::fs::MetadataExt;
        assert_eq!(
            std::fs::metadata(&token_path).unwrap().mode() & 0o777,
            0o600
        );
    }

    #[tokio::test]
    async fn enroll_denied_is_terminal() {
        let mut edge = MockEdge::new("edgEK=");
        edge.script(vec![
            waiting(),
            PollOutcome {
                status: "denied".to_string(),
                wg_ip: None,
                device_token: None,
            },
        ]);
        let dir = tempfile::tempdir().unwrap();
        let result = enroll(
            &edge,
            &invite_config(),
            &dir.path().join("wg-private.key"),
            &dir.path().join("tunnel.json"),
            &dir.path().join("device-token"),
            std::time::Duration::from_millis(1),
            10,
        )
        .await;
        assert!(matches!(result, Err(EnrollError::Denied)));
    }

    #[tokio::test]
    async fn enroll_times_out_after_max_polls() {
        let mut edge = MockEdge::new("edgEK=");
        edge.script(vec![]); // forever waiting
        let dir = tempfile::tempdir().unwrap();
        let result = enroll(
            &edge,
            &invite_config(),
            &dir.path().join("wg-private.key"),
            &dir.path().join("tunnel.json"),
            &dir.path().join("device-token"),
            std::time::Duration::from_millis(1),
            3,
        )
        .await;
        assert!(
            matches!(result, Err(EnrollError::TimedOut(0))),
            "{result:?}"
        );
        // Nothing persisted on a timeout.
        assert!(persisted_tunnel_state(&dir.path().join("tunnel.json")).is_none());
        assert!(persisted_device_token(&dir.path().join("device-token")).is_none());
    }

    #[tokio::test]
    async fn rotate_uses_the_persisted_token() {
        let edge = MockEdge::new("edgEK=");
        let dir = tempfile::tempdir().unwrap();
        let token_path = dir.path().join("device-token");
        persist_device_token(&token_path, "rot-token").unwrap();
        let key_path = dir.path().join("wg-private.key");
        rotate(&edge, &token_path, &key_path).await.expect("rotate");
        let rotated = edge.rotated.lock().unwrap();
        assert_eq!(rotated.len(), 1);
        assert_eq!(rotated[0].0, "rot-token");
        // The pubkey sent is the one derived from the (freshly persisted) key.
        let derived = fortress_core::wg::derive_public_key(
            &std::fs::read_to_string(&key_path).unwrap().trim(),
        )
        .unwrap();
        assert_eq!(rotated[0].1, derived);
    }

    #[test]
    fn tunnel_ip_substitution_replaces_placeholder_only() {
        let tunnel = TunnelConfig {
            iface: "wg0".to_string(),
            ip: "10.10.0.7".to_string(),
            prefix: 24,
            edge_pubkey: "k".to_string(),
            edge_endpoint: "e".to_string(),
            edge_allowed_ips: "10.10.0.0/24".to_string(),
            listen_port: 0,
        };
        let mk = |dest: &str| fortress_core::forwarder::Forward {
            listen_addr: "0.0.0.0:80".to_string(),
            proto: fortress_core::forwarder::Proto::Tcp,
            dest_addr: dest.to_string(),
        };
        let forwards = vec![mk("{tunnel_ip}:80"), mk("127.0.0.1:8080")];
        let out = substitute_tunnel_ip(&forwards, &tunnel);
        assert_eq!(out[0].dest_addr, "10.10.0.7:80");
        assert_eq!(
            out[1].dest_addr, "127.0.0.1:8080",
            "no placeholder, no change"
        );
    }
}
