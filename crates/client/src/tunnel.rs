// SPDX-License-Identifier: AGPL-3.0-or-later
//! Client-owned WireGuard tunnel (ADR-025).
//!
//! The customer box generates + persists its own WG keypair and owns the
//! wg0 interface — there is no operator key-file step and no NixOS wg0
//! module to keep in sync. The client brings wg0 up before the forwarder
//! binds, so the forwarder's tunnel-IP listeners have an address. The
//! private key lives at a persisted path (under `StateDirectory=cococoir`)
//! and is applied via `wg set` — it is never written to `/etc/wireguard`
//! and never sent anywhere (ADR-025: the edge holds only the public key).

use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;
use thiserror::Error;

use cococoir_core::wg;

const DEFAULT_IFACE: &str = "wg0";
const DEFAULT_PREFIX: u8 = 24;

/// Client-side tunnel config. All values are stable for a registered
/// customer: the edge assigns the tunnel IP once (e.g. `10.10.0.3`) and
/// it does not change across reboots.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TunnelConfig {
    /// The tunnel interface name.
    #[serde(default = "default_iface")]
    pub iface: String,
    /// The customer's tunnel address on the interface, e.g. `10.10.0.3`.
    pub ip: String,
    /// Tunnel prefix length, e.g. `24`.
    #[serde(default = "default_prefix")]
    pub prefix: u8,
    /// The edge's WG public key (from `GET /pubkey`).
    pub edge_pubkey: String,
    /// The edge's dial-out endpoint, e.g. `62.238.111.21:51820`.
    pub edge_endpoint: String,
    /// The edge's tunnel range the box routes over the tunnel.
    pub edge_allowed_ips: String,
    /// Local listen port; 0 = ephemeral (dial-out only).
    #[serde(default)]
    pub listen_port: u16,
}

fn default_iface() -> String {
    DEFAULT_IFACE.to_string()
}
fn default_prefix() -> u8 {
    DEFAULT_PREFIX
}

/// The persisted private-key path. Under `StateDirectory=cococoir`, the
/// one writable path under `ProtectSystem=strict`.
pub fn key_path() -> PathBuf {
    PathBuf::from("/var/lib/cococoir/wg-private.key")
}

/// Tunnel bring-up failure.
#[derive(Debug, Error)]
pub enum TunnelError {
    #[error("keypair persistence failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid persisted key: {0}")]
    Key(wg::WgKeyError),
    #[error("command failed ({cmd}): {stderr}")]
    Command { cmd: String, stderr: String },
}

/// Ensure a keypair exists at `path`, generating + persisting a fresh one
/// (0600) if missing. Never regenerates an existing key. Returns the
/// public key.
pub fn ensure_keypair(path: &Path) -> Result<String, TunnelError> {
    if let Ok(text) = std::fs::read_to_string(path) {
        let key = text.trim();
        if !key.is_empty() {
            return wg::derive_public_key(key).map_err(TunnelError::Key);
        }
    }
    let (pubkey, privkey) = wg::generate_keypair();
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true).mode(0o600);
    match opts.open(path) {
        Ok(mut file) => {
            use std::io::Write;
            file.write_all(privkey.as_bytes())?;
            file.write_all(b"\n")?;
            Ok(pubkey)
        }
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            // A concurrent process won the race; use the persisted key.
            let text = std::fs::read_to_string(path)?;
            wg::derive_public_key(text.trim()).map_err(TunnelError::Key)
        }
        Err(err) => Err(TunnelError::Io(err)),
    }
}

/// Ensure `wg0` exists and is configured with the persisted key + edge
/// peer, then bring it up. Idempotent: a repeated call on an already-up
/// interface is a no-op sequence.
pub fn bring_up_wg0(cfg: &TunnelConfig, key_path: &Path) -> Result<(), TunnelError> {
    if !link_exists(&cfg.iface) {
        run("ip", &["link", "add", &cfg.iface, "type", "wireguard"])?;
    }
    run(
        "wg",
        &[
            "set",
            &cfg.iface,
            "listen-port",
            &cfg.listen_port.to_string(),
            "private-key",
            key_path.to_str().expect("key path is utf8"),
        ],
    )?;
    run(
        "wg",
        &[
            "set",
            &cfg.iface,
            "peer",
            &cfg.edge_pubkey,
            "allowed-ips",
            &cfg.edge_allowed_ips,
            "endpoint",
            &cfg.edge_endpoint,
            "persistent-keepalive",
            "25",
        ],
    )?;
    if !addr_present(&cfg.iface, &cfg.ip) {
        run(
            "ip",
            &[
                "addr",
                "add",
                &format!("{}/{}", cfg.ip, cfg.prefix),
                "dev",
                &cfg.iface,
            ],
        )?;
    }
    run("ip", &["link", "set", &cfg.iface, "up"])?;
    Ok(())
}

/// True if the named link already exists in the kernel.
fn link_exists(iface: &str) -> bool {
    Command::new("ip")
        .args(["link", "show", iface])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// True if the IP (token, any prefix) is already assigned to the iface.
/// `ip addr show` renders each address as `<ip>/<prefix>`; strip the
/// prefix so a restart detects an already-assigned `10.10.0.3/24` and
/// does not re-add it (idempotency — a blind re-add fails with
/// "Address already assigned").
fn addr_present(iface: &str, ip: &str) -> bool {
    let Ok(output) = Command::new("ip").args(["addr", "show", "dev", iface]).output() else {
        return false;
    };
    addr_token_matches(&String::from_utf8_lossy(&output.stdout), ip)
}

/// True if any whitespace token in `ip addr show` output matches `ip`,
/// ignoring the `/prefix` suffix (rendered as `10.10.0.3/24`).
fn addr_token_matches(text: &str, ip: &str) -> bool {
    text.split_whitespace().any(|token| token.split('/').next() == Some(ip))
}

/// Run a single external command (`ip` or `wg`), returning its stderr on
/// failure.
fn run(prog: &str, args: &[&str]) -> Result<(), TunnelError> {
    let output = Command::new(prog).args(args).output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(TunnelError::Command {
            cmd: format!("{} {}", prog, args.join(" ")),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ensure_keypair_generates_persists_and_derives() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wg-private.key");
        let pubkey = ensure_keypair(&path).unwrap();
        // Persisted as the private key; the pubkey derives from it.
        let persisted = std::fs::read_to_string(&path).unwrap();
        assert_eq!(wg::derive_public_key(persisted.trim()).unwrap(), pubkey);
        // 0600 mode.
        use std::os::unix::fs::MetadataExt;
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
    }

    #[test]
    fn ensure_keypair_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wg-private.key");
        let first = ensure_keypair(&path).unwrap();
        let persisted = std::fs::read_to_string(&path).unwrap();
        // A second call returns the same key and does not rewrite the file.
        let second = ensure_keypair(&path).unwrap();
        assert_eq!(first, second);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), persisted);
    }

    #[test]
    fn addr_token_matches_ignores_prefix() {
        // `ip addr show` renders each address as `10.10.0.3/24`; a restart
        // must recognize it as already present rather than re-add (which
        // fails with "Address already assigned").
        let out = "1: wg0: <POINTOPOINT,NOARP> mtu 1420\n    inet 10.10.0.3/24 scope global wg0\n";
        assert!(addr_token_matches(out, "10.10.0.3"));
        assert!(addr_token_matches(out, "10.10.0.3/24".split('/').next().unwrap()));
        assert!(!addr_token_matches(out, "10.10.0.4"));
    }

    #[test]
    fn tunnel_config_parses() {
        let cfg: TunnelConfig = serde_json::from_str(
            r#"{"ip":"10.10.0.3","edge_pubkey":"lX+5lGEF1qDJEag13Kymyxy/SJH63LPxKTvMg50WE2E=","edge_endpoint":"62.238.111.21:51820","edge_allowed_ips":"10.10.0.0/24"}"#,
        )
        .unwrap();
        assert_eq!(cfg.iface, "wg0");
        assert_eq!(cfg.prefix, 24);
        assert_eq!(cfg.listen_port, 0);
    }

    #[test]
    fn tunnel_config_rejects_unknown_field() {
        assert!(
            serde_json::from_str::<TunnelConfig>(
                r#"{"ip":"10.10.0.3","edge_pubkey":"x","edge_endpoint":"e","edge_allowed_ips":"a","bogus":1}"#,
            )
            .is_err()
        );
    }
}