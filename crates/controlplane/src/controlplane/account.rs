// SPDX-License-Identifier: AGPL-3.0-or-later
//! Account model + sessions + magic-link auth (Redis).
//!
//! The account is the identity layer the enrollment flow builds on:
//! email-keyed login + an internal UUID (the owner reference machines
//! attach to, and the future auth-provider attach point — OIDC/phone),
//! status `pending` → `active` after a single-use magic-link verify.
//! One "email a token" primitive powers both account verify and
//! password reset. Passwords are bcrypt-hashed, never plaintext (T2
//! acceptance). An account has NO public username — accounts are not
//! hostnames; machines are (T4 amendment).
//!
//! Redis keys (all live in the same Redis as the machines):
//!   fortress:account:{email}     → AccountRecord JSON (permanent)
//!   fortress:verify:{token}      → email (24h TTL, GETDEL single-use)
//!   fortress:reset:{token}       → email (24h TTL, GETDEL single-use)
//!   fortress:session:{token}     → email (7d TTL)
//!
//! The methods live on `impl ControlPlane` so they share the process's
//! Redis client + `root_domain`; the mailer is injected (`&dyn Mailer`)
//! so tests use a mock and the web layer passes the process mailer.
//! No boot globals are read here — every account test constructs a
//! `ControlPlane` directly and injects a `MockMailer`.

use crate::controlplane::mail::Mailer;
use crate::controlplane::pairing::invite_key;
use crate::controlplane::{ControlPlane, ControlPlaneError};

use rand_core::{OsRng, RngCore};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

const VERIFY_TOKEN_TTL_SECS: u64 = 24 * 60 * 60;
const RESET_TOKEN_TTL_SECS: u64 = 24 * 60 * 60;
const SESSION_TTL_SECS: u64 = 7 * 24 * 60 * 60;

fn account_key(email: &str) -> String {
    format!("fortress:account:{email}")
}
fn verify_key(token: &str) -> String {
    format!("fortress:verify:{token}")
}
fn reset_key(token: &str) -> String {
    format!("fortress:reset:{token}")
}
fn session_key(token: &str) -> String {
    format!("fortress:session:{token}")
}

/// Account lifecycle + auth failure surface. Generic where it must be
/// (login errors never distinguish "no such account" from "wrong
/// password") and specific where it helps the web layer (not-verified,
/// duplicate email, invalid token).
#[derive(Debug, thiserror::Error)]
pub enum AccountError {
    #[error("invalid email: {0}")]
    InvalidEmail(String),
    #[error("invalid password: {0}")]
    InvalidPassword(String),
    #[error("account already exists: {0}")]
    DuplicateEmail(String),
    #[error("account not found")]
    NotFound,
    #[error("invalid credentials")]
    InvalidCredentials,
    #[error("account not verified: {0}")]
    NotVerified(String),
    #[error("invalid or expired token")]
    InvalidToken,
    #[error("corrupt account record: {0}")]
    Corrupt(String),
    #[error("redis error: {0}")]
    Redis(#[from] redis::RedisError),
    #[error("mailer: {0}")]
    Mail(#[from] crate::controlplane::mail::MailerError),
}

/// What a password-reset request did. The outcome is explicit because
/// enumeration already is: signup rejects a duplicate email with a
/// user-visible "already exists" error, so hiding the same fact here
/// protected nothing while confusing legitimate users who typo'd or
/// forgot which address they signed up with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetOutcome {
    /// The email has an account; the single-use link went out.
    Sent,
    /// No account for that email; nothing was sent, and the caller says
    /// so.
    UnknownEmail,
}

/// What a verification-email resend did. Explicit for the same reason as
/// [`ResetOutcome`] — registration status already leaks via signup's
/// duplicate-email error, so the caller can tell the truth instead of
/// guessing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResendVerifyOutcome {
    /// Pending account; a fresh single-use link went out.
    Sent,
    /// The account is already active — nothing to verify, no email sent.
    AlreadyActive,
    /// No account for that email; nothing was sent.
    UnknownEmail,
}

/// `conn()` returns `ControlPlaneError`; the only error it can produce
/// is a Redis failure, but map everything defensively so `?` is total.
impl From<ControlPlaneError> for AccountError {
    fn from(err: ControlPlaneError) -> Self {
        match err {
            ControlPlaneError::Redis(e) => AccountError::Redis(e),
            other => AccountError::Corrupt(other.to_string()),
        }
    }
}

/// Lifecycle of an account. `pending` until the magic-link verify fires;
/// pairing (T5) requires `active`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AccountStatus {
    Pending,
    Active,
}

/// The durable account record, keyed by email.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountRecord {
    /// Internal owner identity. Machines reference this, never the
    /// email — the attach point for future auth providers (OIDC/phone).
    pub uuid: String,
    pub status: AccountStatus,
    pub password_hash: String,
    /// Billing placeholder (PLAN v3) — no billing ships in this arc.
    pub plan: Option<String>,
}

/// A 32-byte random token, hex-encoded (64 chars). Powers verify,
/// reset, and sessions.
fn random_token() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

/// The magic link for account verification.
pub fn verify_link(domain: &str, token: &str) -> String {
    format!("https://{domain}/verify?token={token}")
}

/// The magic link for password reset.
pub fn reset_link(domain: &str, token: &str) -> String {
    format!("https://{domain}/reset?token={token}")
}

fn verify_body(link: &str) -> String {
    format!("Verify your fortress account:\n\n{link}\n\nThis link expires in 24 hours.")
}

fn reset_body(link: &str) -> String {
    format!("Reset your fortress password:\n\n{link}\n\nThis link expires in 24 hours.")
}

fn validate_email(email: &str) -> Result<(), AccountError> {
    use std::str::FromStr;
    if lettre::message::Mailbox::from_str(email).is_err() {
        return Err(AccountError::InvalidEmail(email.to_string()));
    }
    Ok(())
}

fn validate_password(password: &str) -> Result<(), AccountError> {
    if password.is_empty() {
        return Err(AccountError::InvalidPassword("empty".to_string()));
    }
    if password.len() > 72 {
        return Err(AccountError::InvalidPassword(
            "longer than bcrypt's 72-byte limit".to_string(),
        ));
    }
    Ok(())
}

fn account_from_json(json: String) -> Result<AccountRecord, AccountError> {
    serde_json::from_str(&json).map_err(|e| AccountError::Corrupt(e.to_string()))
}

impl ControlPlane {
    /// Email + password signup. Creates a `pending` account with a
    /// fresh UUID, emails a single-use magic link, and fails (rolling
    /// back) if the mailer rejects the send — a link that never sends
    /// is a signup that never activates. Duplicate email is rejected.
    pub async fn account_signup(
        &self,
        email: &str,
        password: &str,
        mailer: &dyn Mailer,
    ) -> Result<(), AccountError> {
        let email = email.trim().to_lowercase();
        validate_email(&email)?;
        validate_password(password)?;

        let mut conn = self.conn().await?;
        if conn.exists(account_key(&email)).await? {
            return Err(AccountError::DuplicateEmail(email.clone()));
        }

        // validate_password guarantees non-empty ≤72 bytes, the only
        // ways bcrypt::hash can fail — so a failure here is a
        // programmer error, not a password problem.
        let password_hash = bcrypt::hash(password, bcrypt::DEFAULT_COST)
            .expect("bcrypt cannot fail: password is non-empty and ≤72 bytes");
        let account = AccountRecord {
            uuid: Uuid::new_v4().to_string(),
            status: AccountStatus::Pending,
            password_hash,
            plan: None,
        };
        let _: () = conn
            .set(
                account_key(&email),
                serde_json::to_string(&account).unwrap(),
            )
            .await?;

        let token = random_token();
        let _: () = conn
            .set_ex(verify_key(&token), &email, VERIFY_TOKEN_TTL_SECS)
            .await?;

        // A failed send is a failed signup — never a zombie account the
        // customer can't activate. The email becomes reusable and the
        // verify token is destroyed with it: it is a single-use
        // capability for an account that no longer exists, and leaving
        // it would dangle for 24h.
        let link = verify_link(self.root_domain, &token);
        if let Err(err) = mailer
            .send(&email, "Verify your fortress account", &verify_body(&link))
            .await
        {
            let _: Result<(), redis::RedisError> = conn.del(account_key(&email)).await;
            let _: Result<(), redis::RedisError> = conn.del(verify_key(&token)).await;
            return Err(AccountError::Mail(err));
        }
        Ok(())
    }

    /// The account's internal UUID — the owner reference machines
    /// carry. `None` for an unknown email; callers with an email from
    /// an active session can expect.
    pub(crate) async fn account_uuid(&self, email: &str) -> Result<Option<String>, AccountError> {
        let email = email.trim().to_lowercase();
        let mut conn = self.conn().await?;
        let Some(json): Option<String> = conn.get(account_key(&email)).await? else {
            return Ok(None);
        };
        Ok(Some(account_from_json(json)?.uuid))
    }

    /// Delete the logged-in account: every machine's WG peer + live
    /// forwards + per-machine DNS + device tokens, every invite owned
    /// by the email, every session, and the account record itself — in
    /// that order (store entries last, mirroring machine delete's
    /// unwire-first discipline). The box's local data is the box's: the
    /// box just loses remote access (tunnel dead, token revoked) and
    /// can re-enroll under a new account. Never wipes.
    pub async fn account_delete(&self, email: &str) -> Result<(), AccountError> {
        let email = email.trim().to_lowercase();
        let mut conn = self.conn().await?;
        let key = account_key(&email);
        let Some(json): Option<String> = conn.get(&key).await? else {
            return Err(AccountError::NotFound);
        };
        let _account = account_from_json(json)?;

        // Machines: unwire each (peer + forwards + DNS + the record,
        // which carries the device-token hash). Best-effort — the
        // account must die even if one machine's WG/DNS removal hiccups.
        let machines = self.machines_of(&email).await.unwrap_or_default();
        for machine in &machines {
            if let Err(err) = self.delete(&machine.name).await {
                tracing::error!(name = %machine.name, err = %err, "account delete: machine unwire failed");
            }
        }

        // Invites owned by the email (waiting, approved, or denied).
        let invites = self.invites_of(&email).await.unwrap_or_default();
        for (code, _record) in invites {
            let _: () = conn.del(invite_key(&code)).await?;
        }

        // Sessions: any session token whose value is this email. The
        // scan is cursor-complete (one page is not enough in a keyspace
        // with other accounts' sessions).
        let mut cursor = "0".to_string();
        loop {
            let (next, session_keys): (String, Vec<String>) = redis::cmd("SCAN")
                .arg(&cursor)
                .arg("MATCH")
                .arg(session_key("*"))
                .arg("COUNT")
                .arg(100)
                .query_async(&mut conn)
                .await?;
            for skey in session_keys {
                let value: Option<String> = conn.get(&skey).await?;
                if value.as_deref() == Some(email.as_str()) {
                    let _: () = conn.del(&skey).await?;
                }
            }
            if next == "0" {
                break;
            }
            cursor = next;
        }

        // The account record last.
        let _: () = conn.del(&key).await?;
        Ok(())
    }

    /// Consume the single-use verify token and flip the account to
    /// `active`. Atomic via GETDEL: the second click sees no token.
    pub async fn account_verify(&self, token: &str) -> Result<(), AccountError> {
        let mut conn = self.conn().await?;
        let email: Option<String> = redis::cmd("GETDEL")
            .arg(verify_key(token))
            .query_async(&mut conn)
            .await?;
        let Some(email) = email else {
            return Err(AccountError::InvalidToken);
        };
        let key = account_key(&email);
        let Some(json): Option<String> = conn.get(&key).await? else {
            return Err(AccountError::NotFound);
        };
        let mut account = account_from_json(json)?;
        account.status = AccountStatus::Active;
        let _: () = conn
            .set(&key, serde_json::to_string(&account).unwrap())
            .await?;
        Ok(())
    }

    /// Email + password login. Returns the session token (the web layer
    /// sets it as an HttpOnly cookie). Requires an `active` account so
    /// an unverified email cannot pair a box. Failures are generic —
    /// no account enumeration.
    pub async fn account_login(&self, email: &str, password: &str) -> Result<String, AccountError> {
        let email = email.trim().to_lowercase();
        let mut conn = self.conn().await?;
        let Some(json): Option<String> = conn.get(account_key(&email)).await? else {
            return Err(AccountError::InvalidCredentials);
        };
        let account = account_from_json(json)?;
        if !bcrypt::verify(password, &account.password_hash)
            .map_err(|e| AccountError::Corrupt(e.to_string()))?
        {
            return Err(AccountError::InvalidCredentials);
        }
        if account.status != AccountStatus::Active {
            return Err(AccountError::NotVerified(email));
        }
        let session = random_token();
        let _: () = conn
            .set_ex(session_key(&session), &email, SESSION_TTL_SECS)
            .await?;
        Ok(session)
    }

    /// Invalidate a session. Idempotent.
    pub async fn account_logout(&self, session: &str) -> Result<(), AccountError> {
        let mut conn = self.conn().await?;
        let _: () = conn.del(session_key(session)).await?;
        Ok(())
    }

    /// Resolve a session token to its account email. `None` for a
    /// missing/expired session.
    pub async fn session_account(&self, session: &str) -> Result<Option<String>, AccountError> {
        let mut conn = self.conn().await?;
        Ok(conn.get(session_key(session)).await?)
    }

    /// Resend the verification link for a pending account. The outcome
    /// is explicit for the same reason as [`ResetOutcome`]: signup's
    /// duplicate-email error already leaks registration status, so the
    /// caller can tell a pending account "sent", an active one
    /// "already verified", and an unknown email "no account". The old
    /// verify token is left to expire on its own TTL — both are
    /// single-use GETDEL and point at the same email, so a stale one
    /// is harmless.
    pub async fn resend_verification(
        &self,
        email: &str,
        mailer: &dyn Mailer,
    ) -> Result<ResendVerifyOutcome, AccountError> {
        let email = email.trim().to_lowercase();
        let mut conn = self.conn().await?;
        let Some(json): Option<String> = conn.get(account_key(&email)).await? else {
            return Ok(ResendVerifyOutcome::UnknownEmail);
        };
        let account = account_from_json(json)?;
        if account.status == AccountStatus::Active {
            return Ok(ResendVerifyOutcome::AlreadyActive);
        }
        let token = random_token();
        let _: () = conn
            .set_ex(verify_key(&token), &email, VERIFY_TOKEN_TTL_SECS)
            .await?;
        let link = verify_link(self.root_domain, &token);
        mailer
            .send(&email, "Verify your fortress account", &verify_body(&link))
            .await?;
        Ok(ResendVerifyOutcome::Sent)
    }

    /// Request a password reset. Emails a single-use magic link (same
    /// primitive as verify). Unknown emails return
    /// [`ResetOutcome::UnknownEmail`] explicitly — enumeration is
    /// already possible via signup's duplicate-email error, so silence
    /// here buys nothing (see [`ResetOutcome`]).
    pub async fn request_password_reset(
        &self,
        email: &str,
        mailer: &dyn Mailer,
    ) -> Result<ResetOutcome, AccountError> {
        let email = email.trim().to_lowercase();
        let mut conn = self.conn().await?;
        if !conn.exists(account_key(&email)).await? {
            return Ok(ResetOutcome::UnknownEmail);
        }
        let token = random_token();
        let _: () = conn
            .set_ex(reset_key(&token), &email, RESET_TOKEN_TTL_SECS)
            .await?;
        let link = reset_link(self.root_domain, &token);
        mailer
            .send(&email, "Reset your fortress password", &reset_body(&link))
            .await?;
        Ok(ResetOutcome::Sent)
    }

    /// Consume the single-use reset token and replace the password.
    /// Works logged-out; the token is the credential.
    pub async fn reset_password(
        &self,
        token: &str,
        new_password: &str,
    ) -> Result<(), AccountError> {
        validate_password(new_password)?;
        let mut conn = self.conn().await?;
        let email: Option<String> = redis::cmd("GETDEL")
            .arg(reset_key(token))
            .query_async(&mut conn)
            .await?;
        let Some(email) = email else {
            return Err(AccountError::InvalidToken);
        };
        let key = account_key(&email);
        let Some(json): Option<String> = conn.get(&key).await? else {
            return Err(AccountError::NotFound);
        };
        let mut account = account_from_json(json)?;
        account.password_hash = bcrypt::hash(new_password, bcrypt::DEFAULT_COST)
            .expect("bcrypt cannot fail: password is non-empty and ≤72 bytes");
        let _: () = conn
            .set(&key, serde_json::to_string(&account).unwrap())
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::controlplane::dns::MockDnsApiClient;
    use crate::controlplane::mail::MockMailer;
    use crate::controlplane::wg::MockWgClient;
    use crate::controlplane::{SignupOutcome, Subnet64, WgSubnet};

    /// The tests share one real Redis (when REDIS_URL is set). They
    /// never touch the process globals — each builds a `ControlPlane`
    /// locally — so unique emails isolate them from each other.
    fn test_cp() -> Option<ControlPlane> {
        let url = match std::env::var("REDIS_URL") {
            Ok(url) if !url.is_empty() => url,
            _ => return None,
        };
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").unwrap();
        ControlPlane::with_deps(
            &url,
            subnet,
            wg_subnet,
            "example.net",
            "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=",
            wg,
            dns,
        )
        .map(|cp| cp.isolated_alloc(leaked_alloc_key()))
        .ok()
    }

    /// Skip the store-backed tests when no Redis is available (the nix
    /// devshell provides it; CI does not run one) — same convention as
    /// `redis_store_round_trip`.
    fn leaked_alloc_key() -> &'static str {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        Box::leak(format!("fortress:test-alloc:{}-{}", std::process::id(), nanos).into_boxed_str())
    }

    fn skip_without_redis() -> Option<ControlPlane> {
        let cp = test_cp();
        if cp.is_none() {
            eprintln!("skipping: REDIS_URL not set");
        }
        cp
    }

    fn unique_email(label: &str) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{label}-{}-{}@example.com", std::process::id(), nanos)
    }

    fn extract_token(body: &str) -> String {
        let start = body.find("token=").expect("link present") + "token=".len();
        body[start..].lines().next().unwrap().trim().to_string()
    }

    #[test]
    fn link_builders_produce_expected_urls() {
        assert_eq!(
            verify_link("proletariat.tech", "abc"),
            "https://proletariat.tech/verify?token=abc"
        );
        assert_eq!(
            reset_link("proletariat.tech", "abc"),
            "https://proletariat.tech/reset?token=abc"
        );
    }

    #[test]
    fn email_validation() {
        assert!(validate_email("alice@example.com").is_ok());
        assert!(validate_email("ALICE@example.com").is_ok());
        assert!(validate_email("not-an-email").is_err());
        assert!(validate_email("").is_err());
    }

    #[test]
    fn password_validation() {
        assert!(validate_password("hunter2").is_ok());
        assert!(validate_password("").is_err());
        assert!(validate_password(&"x".repeat(73)).is_err());
        assert!(validate_password(&"x".repeat(72)).is_ok());
    }

    #[test]
    fn verify_link_token_round_trips() {
        assert_eq!(extract_token(&verify_body(&verify_link("d", "tok"))), "tok");
    }

    #[tokio::test]
    async fn signup_verify_login_logout_round_trip() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        let email = unique_email("rt");
        cp.account_signup(&email, "hunter2", &mailer)
            .await
            .expect("signup");
        let sent = mailer.sent();
        assert_eq!(sent.len(), 1, "one verify email");
        assert_eq!(sent[0].to, email);
        assert!(sent[0].body.contains("token="), "body has the link");
        let token = extract_token(&sent[0].body);

        // Verify: single-use.
        cp.account_verify(&token).await.expect("verify");
        assert!(matches!(
            cp.account_verify(&token).await,
            Err(AccountError::InvalidToken)
        ));
        assert_eq!(
            cp.account_verify(&token).await.unwrap_err().to_string(),
            "invalid or expired token"
        );

        // Duplicate signup (same email) rejected.
        assert!(matches!(
            cp.account_signup(&email, "pw", &mailer).await,
            Err(AccountError::DuplicateEmail(_))
        ));

        // Wrong password → generic invalid credentials.
        assert!(matches!(
            cp.account_login(&email, "wrong").await,
            Err(AccountError::InvalidCredentials)
        ));

        let session = cp.account_login(&email, "hunter2").await.expect("login");
        assert_eq!(
            cp.session_account(&session).await.unwrap().as_deref(),
            Some(email.as_str())
        );

        // Logout invalidates.
        cp.account_logout(&session).await.expect("logout");
        assert_eq!(cp.session_account(&session).await.unwrap(), None);
    }

    #[tokio::test]
    async fn account_record_has_no_username_field() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        let email = unique_email("uuid");
        cp.account_signup(&email, "hunter2", &mailer)
            .await
            .expect("signup");
        let mut conn = cp.conn().await.unwrap();
        let json: String = conn.get(account_key(&email)).await.unwrap();
        assert!(
            !json.contains("username"),
            "the record carries no username: {json}"
        );
        let account: AccountRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(account.uuid.len(), 36, "uuid is a v4 UUID string");
        assert!(account.uuid.chars().filter(|c| *c == '-').count() == 4);
    }

    #[tokio::test]
    async fn password_never_stored_in_plaintext() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        let email = unique_email("plaintext");
        cp.account_signup(&email, "s3cret", &mailer)
            .await
            .expect("signup");
        let mut conn = cp.conn().await.unwrap();
        let json: String = conn.get(account_key(&email)).await.unwrap();
        assert!(
            !json.contains("s3cret"),
            "password not in the record: {json}"
        );
        assert!(json.contains("$2"), "bcrypt hash present: {json}");
    }

    #[tokio::test]
    async fn password_reset_round_trip_without_session() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        let email = unique_email("reset");
        cp.account_signup(&email, "old-password", &mailer)
            .await
            .expect("signup");
        let verify_token = extract_token(&mailer.sent()[0].body);
        cp.account_verify(&verify_token).await.expect("verify");

        let mailer2 = MockMailer::new();
        let outcome = cp
            .request_password_reset(&email, &mailer2)
            .await
            .expect("reset request");
        assert_eq!(outcome, ResetOutcome::Sent, "known email confirms the send");
        let sent = mailer2.sent();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].to, email);
        let reset_token = extract_token(&sent[0].body);

        cp.reset_password(&reset_token, "new-password")
            .await
            .expect("reset");
        // Old password no longer works; new one does.
        assert!(matches!(
            cp.account_login(&email, "old-password").await,
            Err(AccountError::InvalidCredentials)
        ));
        cp.account_login(&email, "new-password")
            .await
            .expect("new password login");

        // Reset token is single-use.
        assert!(matches!(
            cp.reset_password(&reset_token, "third").await,
            Err(AccountError::InvalidToken)
        ));
    }

    #[tokio::test]
    async fn reset_unknown_email_is_explicit_and_sends_nothing() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        let outcome = cp
            .request_password_reset(&unique_email("ghost"), &mailer)
            .await
            .expect("unknown email still succeeds");
        assert_eq!(outcome, ResetOutcome::UnknownEmail, "explicit outcome");
        assert!(
            mailer.sent().is_empty(),
            "no email sent for unknown account"
        );
    }

    #[tokio::test]
    async fn resend_verification_outcomes_cover_pending_active_unknown() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();

        let pending_email = unique_email("resend-pending");
        cp.account_signup(&pending_email, "hunter2", &mailer)
            .await
            .expect("signup");
        mailer.clear();

        let outcome = cp
            .resend_verification(&pending_email, &mailer)
            .await
            .expect("resend pending");
        assert_eq!(outcome, ResendVerifyOutcome::Sent);
        assert_eq!(mailer.sent().len(), 1, "fresh link emailed");
        assert_eq!(mailer.sent()[0].to, pending_email);
        assert!(
            mailer.sent()[0].body.contains("token="),
            "body has the new link"
        );

        let verify_token = extract_token(&mailer.sent()[0].body);
        cp.account_verify(&verify_token).await.expect("verify");
        mailer.clear();
        let outcome = cp
            .resend_verification(&pending_email, &mailer)
            .await
            .expect("resend active");
        assert_eq!(outcome, ResendVerifyOutcome::AlreadyActive);
        assert!(
            mailer.sent().is_empty(),
            "no email for an already-active account"
        );

        let outcome = cp
            .resend_verification(&unique_email("resend-ghost"), &mailer)
            .await
            .expect("resend unknown");
        assert_eq!(outcome, ResendVerifyOutcome::UnknownEmail);
        assert!(
            mailer.sent().is_empty(),
            "no email for an unknown account"
        );
    }

    #[tokio::test]
    async fn login_requires_active_account() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        let email = unique_email("pending");
        cp.account_signup(&email, "hunter2", &mailer)
            .await
            .expect("signup");
        assert!(matches!(
            cp.account_login(&email, "hunter2").await,
            Err(AccountError::NotVerified(_))
        ));
    }

    /// Tripwire for the send-failure rollback: a failed verify-email
    /// send must undo the whole signup — the account record AND the
    /// verify token (a single-use capability for an account that no
    /// longer exists must not dangle for 24h).
    #[tokio::test]
    async fn signup_mail_failure_rolls_back_everything() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        let mailer = MockMailer::new();
        mailer.fail_sends();
        let email = unique_email("mailfail");
        assert!(matches!(
            cp.account_signup(&email, "pw", &mailer).await,
            Err(AccountError::Mail(_))
        ));
        // No verify token survived pointing at the dead account. (Checked
        // before the re-signup below, which legitimately stores a new
        // pending token for the email.)
        let mut conn = cp.conn().await.unwrap();
        let keys: Vec<String> = redis::cmd("KEYS")
            .arg("fortress:verify:*")
            .query_async(&mut conn)
            .await
            .unwrap();
        let values: Vec<Option<String>> = redis::cmd("MGET")
            .arg(&keys)
            .query_async(&mut conn)
            .await
            .unwrap();
        assert!(
            !values.into_iter().flatten().any(|v| v == email),
            "a dangling verify token survived the signup rollback"
        );
        // The email is reusable: the rollback removed the account.
        cp.account_signup(&email, "pw", &MockMailer::new())
            .await
            .expect("re-signup after mail failure");
    }

    /// Account deletion unwires, never wipes: every machine's WG peer +
    /// forwards + DNS + record, every invite, every session, and the
    /// record are gone; a re-login is InvalidCredentials (no
    /// enumeration breach — the account is simply absent).
    #[tokio::test]
    async fn account_delete_unwires_machines_and_sessions() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        crate::controlplane::set_forwarder_for_tests();
        let mailer = MockMailer::new();
        let email = unique_email("delete");
        cp.account_signup(&email, "hunter2", &mailer)
            .await
            .expect("signup");
        // Activate directly (the verify-token flow is T2's proven job).
        let mut conn = cp.conn().await.unwrap();
        let json: String = redis::AsyncCommands::get(&mut conn, account_key(&email))
            .await
            .unwrap();
        let mut account: AccountRecord = serde_json::from_str(&json).unwrap();
        account.status = AccountStatus::Active;
        let _: () = redis::AsyncCommands::set(
            &mut conn,
            account_key(&email),
            serde_json::to_string(&account).unwrap(),
        )
        .await
        .unwrap();

        // An enrolled machine + a session + an invite. The machine name
        // is cleaned first (the store persists across runs).
        let _ = cp.delete("deleteme").await;
        let _: () = conn.del("fortress:alloc:next").await.unwrap();
        let SignupOutcome::Created(_resp) = cp
            .allocate_machine(
                Some(&account.uuid),
                "deleteme",
                "lX+5lGEF1qDJEag13Kymyxy/SJH63LPxKTvMg50WE2E=",
            )
            .await
            .expect("allocate")
        else {
            panic!("created");
        };
        let session = cp.account_login(&email, "hunter2").await.expect("login");
        let invite_code = cp.invite_create(&email).await.expect("invite");

        // Delete.
        cp.account_delete(&email).await.expect("delete");

        // Machines: unwired and the record is gone.
        let machines = cp.list().await.unwrap();
        assert!(!machines.iter().any(|m| m.name == "deleteme"));
        // Sessions: the login session is dead.
        assert_eq!(cp.session_account(&session).await.unwrap(), None);
        // Invites: gone.
        let invites = cp.invites_of(&email).await.unwrap();
        assert!(!invites.iter().any(|(code, _)| code == &invite_code));
        // The account record: gone — a second delete is NotFound.
        assert!(matches!(
            cp.account_delete(&email).await,
            Err(AccountError::NotFound)
        ));
        // Login is impossible (the record is gone).
        assert!(matches!(
            cp.account_login(&email, "hunter2").await,
            Err(AccountError::InvalidCredentials)
        ));
    }
}
