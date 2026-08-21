// SPDX-License-Identifier: AGPL-3.0-or-later
//! WireGuard kernel-interface client.
//!
//! The control plane allocates customer `/128`s and WG peers in
//! Redis, but the actual WireGuard kernel `wg0` interface must be told
//! about each peer before the tunnel works. That is a `wg set` call.
//!
//! This is a small trait so the control plane can be unit-tested
//! without a real kernel interface: `RealWgClient` shells out to the
//! `wg` binary, `MockWgClient` (test-only) records calls.

use std::process::Command;

use thiserror::Error;

/// The WG interface the control plane manages. WireGuard interfaces
/// are named; the edge's server interface is `wg0`.
const WG_IFACE: &str = "wg0";

/// Errors from invoking `wg`.
#[derive(Debug, Error)]
pub enum WgError {
    #[error("wg exited with status {code}: {stderr}")]
    Command {
        code: i32,
        stderr: String,
    },
    #[error("failed to run wg: {0}")]
    Io(std::io::Error),
}

impl From<std::io::Error> for WgError {
    fn from(err: std::io::Error) -> Self {
        WgError::Io(err)
    }
}

/// A client for the WireGuard kernel interface.
pub trait WgClient: Send + Sync {
    /// Add (or update) a peer on `wg0`. `wg_ip` is the peer's tunnel
    /// address (the forwarder's destination); `pubkey` is the peer's
    /// WireGuard public key. `allowed-ips` is the peer's `/32`.
    fn add_peer(&self, wg_ip: &str, pubkey: &str) -> Result<(), WgError>;
    /// Remove a peer from `wg0` by its public key.
    fn remove_peer(&self, pubkey: &str) -> Result<(), WgError>;
    /// Set the interface's private key (the edge's own identity).
    /// `private_key` is the WireGuard private key (base64, 32 bytes).
    fn set_private_key(&self, private_key: &str) -> Result<(), WgError>;
}

/// Real client: invokes the `wg` binary on `wg0`.
#[derive(Debug, Clone, Default)]
pub struct RealWgClient {
    // Extensible: could hold an interface name / path override.
}

/// The process's real WG client. Zero-size struct, so the `LazyLock`
/// is effectively free — the control plane stores `&'static dyn
/// WgClient` (process-lifetime data, not an `Arc`; see
/// `writing/human/lifetimes_in_rust.md`). Tests inject a leaked mock
/// instead.
pub static REAL_WG_CLIENT: std::sync::LazyLock<RealWgClient> =
    std::sync::LazyLock::new(RealWgClient::new);

impl RealWgClient {
    pub fn new() -> Self {
        Self::default()
    }

    fn run(&self, args: &[&str]) -> Result<(), WgError> {
        let output = Command::new("wg")
            .arg("set")
            .arg(WG_IFACE)
            .args(args)
            .output()?;
        if output.status.success() {
            Ok(())
        } else {
            Err(WgError::Command {
                code: output.status.code().unwrap_or(-1),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            })
        }
    }
}

impl WgClient for RealWgClient {
    fn add_peer(&self, wg_ip: &str, pubkey: &str) -> Result<(), WgError> {
        self.run(&["peer", pubkey, "allowed-ips", &format!("{wg_ip}/32")])
    }

    fn remove_peer(&self, pubkey: &str) -> Result<(), WgError> {
        self.run(&["peer", pubkey, "remove"])
    }

    fn set_private_key(&self, private_key: &str) -> Result<(), WgError> {
        // `wg set` reads the private key from a file (it won't take it
        // as an argv to avoid leaking it into process listings). Write
        // it to a temp file, set, and remove.
        let path = std::env::temp_dir().join("cococoir-edge-private.key");
        std::fs::write(&path, format!("{private_key}\n"))?;
        let result = self.run(&["private-key", path.to_str().expect("temp path is utf8")]);
        let _ = std::fs::remove_file(&path);
        result
    }
}

/// A test client that records calls instead of touching the kernel.
#[derive(Debug, Default)]
pub struct MockWgClient {
    pub added: std::sync::Mutex<Vec<(String, String)>>,
    pub removed: std::sync::Mutex<Vec<String>>,
    pub private_keys: std::sync::Mutex<Vec<String>>,
}

impl MockWgClient {
    pub fn new() -> Self {
        Self::default()
    }
}

impl WgClient for MockWgClient {
    fn add_peer(&self, wg_ip: &str, pubkey: &str) -> Result<(), WgError> {
        self.added
            .lock()
            .unwrap()
            .push((wg_ip.to_string(), pubkey.to_string()));
        Ok(())
    }

    fn remove_peer(&self, pubkey: &str) -> Result<(), WgError> {
        self.removed.lock().unwrap().push(pubkey.to_string());
        Ok(())
    }

    fn set_private_key(&self, private_key: &str) -> Result<(), WgError> {
        self.private_keys
            .lock()
            .unwrap()
            .push(private_key.to_string());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_records_add_and_remove() {
        let mock = MockWgClient::new();
        mock.add_peer("10.10.0.2", "pub2").unwrap();
        mock.add_peer("10.10.0.3", "pub3").unwrap();
        mock.remove_peer("pub2").unwrap();
        assert_eq!(mock.added.lock().unwrap().len(), 2);
        assert_eq!(&*mock.removed.lock().unwrap(), &vec!["pub2".to_string()]);
    }

    #[test]
    fn mock_add_replaces_same_peer() {
        let mock = MockWgClient::new();
        mock.add_peer("10.10.0.2", "pub2").unwrap();
        mock.add_peer("10.10.0.2", "pub2").unwrap();
        assert_eq!(mock.added.lock().unwrap().len(), 2);
    }
}
