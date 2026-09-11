// SPDX-License-Identifier: AGPL-3.0-or-later
//! Resolved edge secrets — the single process-lifetime secret source.
//!
//! The contract is `secretspec.toml` (committed next to this crate): a
//! value-free declaration of the edge's secret *names* + whether each is
//! required. [`declare_secrets!`] reads it at **compile time** and
//! generates the typed [`SecretSpec`] struct (a required secret is a
//! `String`, not an `Option`), so a renamed/removed secret is a compile
//! error, never a silent runtime surprise.
//!
//! Values resolve at **runtime** from the dotenv provider
//! (`/etc/fortress/edge.env`), through the macro-generated
//! `SecretSpec::builder().load()`.
//!
//! [`SECRETS`] is a process-lifetime global (`LazyLock`), the same shape
//! as the control-plane globals (see
//! `writing/human/lifetimes_in_rust.md`). It is *synchronous* resolution
//! of file IO, and a missing secret is catastrophic — the box cannot run
//! without its DNS zone + admin key — so it panics rather than returning
//! `Result`, which makes `LazyLock` (not `OnceLock`/`tokio::OnceCell`)
//! the honest tool. Consumers read it through the typed accessors below;
//! the DNS/auth modules derive their own `LazyLock`s from it.

secretspec_derive::declare_secrets!("secretspec.toml");

use std::sync::LazyLock;

/// The resolved edge secrets. Initialized once on first access (forced
/// early by `init_globals` so a missing secret fails boot, not the first
/// signup). Panics on failure — the box is unusable without these.
pub(crate) static SECRETS: LazyLock<secretspec::Resolved<SecretSpec>> = LazyLock::new(|| {
    SecretSpec::builder()
        .with_provider("dotenv:/etc/fortress/edge.env")
        // An explicit reason satisfies the default `require_reason =
        // "agents"` policy (the systemd process isn't an agent, but a
        // reason gives the audit log a human-readable provenance and
        // stays correct if the policy ever becomes "always").
        .with_reason("fortress-edge boot")
        .load()
        .expect("edge secrets must resolve at boot")
});

/// The root domain customer hostnames live under, e.g. `proletariat.tech`.
pub fn root_domain() -> &'static str {
    &SECRETS.secrets.root_domain
}

/// The SHA-256 of the admin API key, decoded to raw bytes for the
/// constant-time check. Decoded once, cached for the process lifetime.
pub fn admin_key_hash() -> &'static [u8; 32] {
    static HASH: LazyLock<[u8; 32]> = LazyLock::new(|| {
        decode_hash_hex(&SECRETS.secrets.admin_key_hash)
            .expect("ADMIN_KEY_HASH is valid hex for a 32-byte hash")
    });
    &HASH
}

/// The shared WireGuard private key for the edge's `wg0` interface
/// (ADR-029 / edge-ha T3). One keypair for both nodes — the survivor
/// presents the same peer identity, so a re-handshake just works.
/// `&'static` because `SECRETS` is process-lifetime.
pub fn wg_private_key() -> &'static str {
    &SECRETS.secrets.wg_private_key
}

/// The SMTP submission relay host, when configured. Absent → the
/// console mailer is used (dev/test); present → the SmtpMailer is used
/// and a broken config is a boot error, never a silent fallback.
pub fn smtp_host() -> Option<&'static str> {
    SECRETS.secrets.smtp_host.as_deref()
}

/// The SMTP submission port (STARTTLS). Defaults to 587 in the mailer.
pub fn smtp_port() -> Option<&'static str> {
    SECRETS.secrets.smtp_port.as_deref()
}

/// The SMTP submission auth user (may be absent for relays that need
/// no auth).
pub fn smtp_user() -> Option<&'static str> {
    SECRETS.secrets.smtp_user.as_deref()
}

/// The SMTP submission auth password.
pub fn smtp_pass() -> Option<&'static str> {
    SECRETS.secrets.smtp_pass.as_deref()
}

/// The envelope From for outbound mail. Defaults to
/// `accounts@{root_domain}` when MAIL_FROM is absent, so a domain
/// migration is a `ROOT_DOMAIN` change, not a code change.
pub fn mail_from() -> String {
    SECRETS
        .secrets
        .mail_from
        .clone()
        .unwrap_or_else(|| format!("accounts@{}", root_domain()))
}

/// Decode a lowercase hex SHA-256 into a `[u8; 32]`. `None` on malformed
/// hex or a length that isn't exactly 64 chars — the two ways the
/// operator-supplied hash can be wrong. Pure + total, so it is unit
/// testable without touching the boot-only `SECRETS`.
fn decode_hash_hex(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    hex::decode(hex).ok()?.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The value-free contract mirrors the committed `secretspec.toml`:
    /// six required secrets + five optional SMTP secrets under the
    /// default profile. Kept in lockstep with the real file by
    /// convention — a drift here is caught when the real file's
    /// `declare_secrets!` no longer matches.
    const CONTRACT: &str = r#"
[project]
name = "fortress-edge"
revision = "1.0"

[profiles.default]
DNS_ZONE_ID = { description = "Hetzner DNS zone id", required = true }
DNS_ZONE_NAME = { description = "Hetzner DNS zone apex", required = true }
DNS_TOKEN = { description = "Hetzner DNS API token", required = true }
ROOT_DOMAIN = { description = "Root domain", required = true }
ADMIN_KEY_HASH = { description = "SHA-256 hex of the admin API key", required = true }
WG_PRIVATE_KEY = { description = "Shared edge wg0 private key", required = true }
SMTP_HOST = { description = "SMTP submission relay host", required = false }
SMTP_PORT = { description = "SMTP submission port", required = false }
SMTP_USER = { description = "SMTP submission auth user", required = false }
SMTP_PASS = { description = "SMTP submission auth password", required = false }
MAIL_FROM = { description = "Envelope From", required = false }
"#;

    /// Write a temp `secretspec.toml` + dotenv and resolve via the
    /// untyped 0.19.1 machinery (`Secrets::load_from` + `set_provider`
    /// + `resolve`) — the same resolution path the macro-generated
    /// `SECRETS::load()` takes, driven with an explicit path because a
    /// test cannot control the process CWD discovery or the hardcoded
    /// `/etc/fortress/edge.env` provider.
    fn resolve_contract(dotenv: &str) -> secretspec::ResolveResponse {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "fortress-secret-test-{}-{}",
            std::process::id(),
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let toml_path = dir.join("secretspec.toml");
        let env_path = dir.join("edge.env");
        std::fs::write(&toml_path, CONTRACT).unwrap();
        std::fs::write(&env_path, dotenv).unwrap();
        let mut spec = secretspec::Secrets::load_from(&toml_path).unwrap();
        spec.set_provider(format!("dotenv:{}", env_path.display()));
        spec.with_reason("unit test").resolve().unwrap()
    }

    fn env_with_all_values() -> String {
        [
            "DNS_ZONE_ID=zone123",
            "DNS_ZONE_NAME=example.net",
            "DNS_TOKEN=sekrit-token",
            "ROOT_DOMAIN=example.net",
            "ADMIN_KEY_HASH=0000000000000000000000000000000000000000000000000000000000000000",
            "WG_PRIVATE_KEY=KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=",
        ]
        .join("\n")
    }

    fn resolved_value<'a>(resp: &'a secretspec::ResolveResponse, name: &str) -> &'a str {
        resp.secrets
            .get(name)
            .and_then(|s| s.value.as_deref())
            .unwrap_or_else(|| panic!("secret {name} resolved to a value"))
    }

    #[test]
    fn resolves_all_six_required_secrets_from_dotenv() {
        let resp = resolve_contract(&env_with_all_values());
        assert!(resp.missing_required.is_empty(), "no missing required");
        assert_eq!(resolved_value(&resp, "DNS_ZONE_ID"), "zone123");
        assert_eq!(resolved_value(&resp, "DNS_ZONE_NAME"), "example.net");
        assert_eq!(resolved_value(&resp, "DNS_TOKEN"), "sekrit-token");
        assert_eq!(resolved_value(&resp, "ROOT_DOMAIN"), "example.net");
        // The declared hash round-trips through the hex decoder.
        let hash = resolved_value(&resp, "ADMIN_KEY_HASH");
        assert!(decode_hash_hex(hash).is_some());
        // The shared wg0 key round-trips as a WireGuard private key.
        let wg_key = resolved_value(&resp, "WG_PRIVATE_KEY");
        assert_eq!(wg_key.len(), 44); // base64, 32 bytes
    }

    #[test]
    fn missing_required_secret_fails_resolution() {
        // Drop the DNS_TOKEN line: resolution must report it missing.
        let dotenv = env_with_all_values().replace("\nDNS_TOKEN=sekrit-token", "");
        let resp = resolve_contract(&dotenv);
        assert!(
            resp.missing_required.contains(&"DNS_TOKEN".to_string()),
            "DNS_TOKEN reported missing"
        );
        // And the fail-fast invariant: no secret carries a value when a
        // required one is missing.
        assert!(resp.secrets.is_empty());
    }

    #[test]
    fn optional_smtp_secrets_resolve_when_present() {
        let dotenv = format!(
            "{}\nSMTP_HOST=smtp.example.com\nSMTP_PORT=587\nSMTP_USER=bob\nSMTP_PASS=sekrit\nMAIL_FROM=accounts@example.com",
            env_with_all_values()
        );
        let resp = resolve_contract(&dotenv);
        assert!(resp.missing_required.is_empty(), "no missing required");
        assert_eq!(resolved_value(&resp, "SMTP_HOST"), "smtp.example.com");
        assert_eq!(resolved_value(&resp, "SMTP_PORT"), "587");
        assert_eq!(resolved_value(&resp, "SMTP_USER"), "bob");
        assert_eq!(resolved_value(&resp, "SMTP_PASS"), "sekrit");
        assert_eq!(resolved_value(&resp, "MAIL_FROM"), "accounts@example.com");
    }

    #[test]
    fn absent_smtp_secrets_still_resolve_and_are_nullable() {
        // The dev/L2 case: no SMTP_* in edge.env, no MAIL_FROM. The
        // required five still resolve; the optional fields are reported
        // as missing-optional (no value, no error) so the mailer falls
        // back to the console.
        let resp = resolve_contract(&env_with_all_values());
        assert!(resp.missing_required.is_empty(), "no missing required");
        for name in ["SMTP_HOST", "SMTP_PORT", "SMTP_USER", "SMTP_PASS", "MAIL_FROM"] {
            assert!(
                resp.missing_optional.contains(&name.to_string()),
                "{name} reported missing-optional"
            );
            assert!(
                resp.secrets.get(name).is_none(),
                "{name} carries no value when absent"
            );
        }
    }

    #[test]
    fn malformed_admin_hash_rejected() {
        assert!(decode_hash_hex("abc").is_none()); // too short
        assert!(decode_hash_hex("z".repeat(64).as_str()).is_none()); // non-hex
        assert!(decode_hash_hex(&"0".repeat(63)).is_none()); // wrong length
        let good = "0".repeat(64);
        assert!(decode_hash_hex(&good).is_some());
    }

    #[test]
    fn valid_admin_hash_decodes_to_32_bytes() {
        let raw = "ff".repeat(32);
        let decoded = decode_hash_hex(&raw).expect("decodes");
        assert_eq!(decoded.len(), 32);
        assert_eq!(decoded[0], 0xff);
        assert_eq!(decoded[31], 0xff);
    }
}