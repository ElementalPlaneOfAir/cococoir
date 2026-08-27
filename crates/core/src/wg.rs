// SPDX-License-Identifier: AGPL-3.0-or-later
//! WireGuard keypair helpers shared by the edge (control plane) and the
//! customer box (client).
//!
//! Both systems shell out to the `wg` binary for the live interface; this
//! module holds the pure key-generation/derivation crypto so it lives in
//! one place instead of being duplicated per crate. ADR-025: the client
//! generates + persists its own keypair and sends only the public key to
//! the edge — the edge never holds a customer private key.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use thiserror::Error;
use x25519_dalek::{PublicKey, StaticSecret};

/// A supplied key was not a valid WireGuard key (32 bytes of base64).
#[derive(Debug, Error)]
pub enum WgKeyError {
    #[error("not a valid wireguard key (expected 32 bytes of base64)")]
    Invalid,
}

/// Generate a fresh WireGuard keypair as base64 strings: `(public,
/// private)`.
pub fn generate_keypair() -> (String, String) {
    use rand_core::OsRng;
    let secret = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);
    (B64.encode(public.as_bytes()), B64.encode(secret.to_bytes()))
}

/// Derive the base64 public key from a base64 private key. Validates the
/// private key is exactly 32 bytes.
pub fn derive_public_key(private_key: &str) -> Result<String, WgKeyError> {
    let bytes: [u8; 32] = B64
        .decode(private_key)
        .map_err(|_| WgKeyError::Invalid)?
        .try_into()
        .map_err(|_| WgKeyError::Invalid)?;
    let secret = StaticSecret::from(bytes);
    let public = PublicKey::from(&secret);
    Ok(B64.encode(public.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keypair_round_trips_through_derive() {
        let (pubkey, privkey) = generate_keypair();
        assert_eq!(B64.decode(&pubkey).unwrap().len(), 32);
        assert_eq!(B64.decode(&privkey).unwrap().len(), 32);
        // Deterministic: deriving the pubkey from the priv key matches.
        assert_eq!(derive_public_key(&privkey).unwrap(), pubkey);
    }

    #[test]
    fn derive_rejects_malformed_keys() {
        assert!(derive_public_key("not-base64").is_err());
        assert!(derive_public_key("aGVsbG8gd29ybGQhIQ==").is_err()); // 17 bytes, not 32
        assert!(derive_public_key("").is_err());
    }

    #[test]
    fn two_generations_differ() {
        let (p1, _) = generate_keypair();
        let (p2, _) = generate_keypair();
        assert_ne!(p1, p2);
    }
}