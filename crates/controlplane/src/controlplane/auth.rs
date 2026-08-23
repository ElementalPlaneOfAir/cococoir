// SPDX-License-Identifier: AGPL-3.0-or-later
//! Admin-key bearer auth for the control plane.
//!
//! A single admin API key guards every control-plane operation except
//! `/pubkey`. The process stores only the **SHA-256 of the key** (from
//! `secret.rs`), not the key itself — so a compromise of the process's
//! memory or the hash does not hand an attacker the credential. The
//! presented bearer token is SHA-256'd and compared in constant time.
//!
//! This is *convenience gating*, not a strong boundary: the plaintext
//! key lives beside the hash in `edge.env` while we stand the service
//! up, so anyone with root on the box already has it (see the proposal's
//! strongest objection). The honest claims are (1) the process never
//! reads the plaintext, and (2) moving the hash to a stricter store
//! (OpenBao/BWS/SOPS) is a provider-URI change, not a code change.

use poem::Request;
use poem_openapi::auth::Bearer;
use poem_openapi::SecurityScheme;

use crate::controlplane::secret::admin_key_hash;

/// The admin key, extracted from `Authorization: Bearer <key>`. Takes
/// `AdminKey` as a handler arg to require auth on an operation; omit it
/// to leave an operation open (like `/pubkey`).
#[derive(SecurityScheme)]
#[oai(ty = "bearer", checker = "check_admin_key")]
pub struct AdminKey(Bearer);

/// Check the presented bearer token against the admin key hash.
///
/// Returns `Some` with the original token on success, `None` on
/// mismatch/missing — the poem-openapi convention for "General
/// Authorization error" (401). Constant-time comparison so a timing side
/// channel cannot recover the hash byte-by-byte.
async fn check_admin_key(_req: &Request, bearer: Bearer) -> Option<Bearer> {
    verify_token(&bearer.token, admin_key_hash()).then_some(bearer)
}

/// True iff `presented`'s SHA-256 equals `expected_hash` (constant
/// time). Pure and total — the expected hash is supplied so tests
/// exercise the comparison without touching the boot-only
/// [`admin_key_hash`] global.
pub fn verify_token(presented: &str, expected_hash: &[u8; 32]) -> bool {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(presented.as_bytes());
    subtle::ConstantTimeEq::ct_eq(&digest[..], &expected_hash[..]).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest;

    // SHA-256 of "the-right-key", decoded. Computed once; the test
    // asserts the constant-time comparison against a fixed reference,
    // independent of the boot-only secrets global.
    fn right_key_hash() -> [u8; 32] {
        sha2::Sha256::digest(b"the-right-key").into()
    }

    #[test]
    fn verify_matches_correct_key() {
        assert!(verify_token("the-right-key", &right_key_hash()));
    }

    #[test]
    fn verify_rejects_wrong_key() {
        assert!(!verify_token("the-wrong-key", &right_key_hash()));
    }

    #[test]
    fn verify_rejects_empty_token() {
        assert!(!verify_token("", &right_key_hash()));
    }

    #[test]
    fn verify_rejects_different_hash() {
        // A non-empty wrong hash must also fail.
        let other = sha2::Sha256::digest(b"other");
        assert!(!verify_token("the-right-key", &other.into()));
    }
}