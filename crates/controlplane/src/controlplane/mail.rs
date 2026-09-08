// SPDX-License-Identifier: AGPL-3.0-or-later
//! Outbound email: the `Mailer` trait + SMTP/console implementations.
//!
//! The trait is deliberately minimal — `send(to, subject, body)` —
//! because that is exactly the SMTP submission contract (RFC 6409).
//! This is the self-host seam: Resend, Postmark, and a future
//! self-hosted MTA (postfix/exim) all speak SMTP submission, so
//! switching provider is a secrets change (SMTP_HOST/PORT/USER/PASS),
//! never an interface change. A console mailer replaces the relay when
//! the SMTP secrets are absent (dev/test/L2): it prints the message, so
//! a magic link is visible in the boot log without any relay.
//!
//! A configured-but-broken relay is a boot error (same philosophy as
//! [`super::secret::SECRETS`]) — never a silent fallback to the console,
//! which would turn a config mistake into an email black hole.

use async_trait::async_trait;
use lettre::message::header::ContentType;
use lettre::transport::smtp::authentication::Credentials;
use lettre::transport::smtp::AsyncSmtpTransport;
use lettre::{AsyncTransport, Message, Tokio1Executor};
use std::sync::Mutex;

use super::secret;

/// Why sending failed. The caller decides whether a failed email is
/// fatal (a verify/reset link that never sends blocks activation) — the
/// mailer itself never panics.
#[derive(Debug, thiserror::Error)]
pub enum MailerError {
    #[error("address: {0}")]
    Address(#[from] lettre::address::AddressError),
    #[error("message: {0}")]
    Build(#[from] lettre::error::Error),
    #[error("smtp: {0}")]
    Smtp(#[from] lettre::transport::smtp::Error),
    /// Injected by the [`MockMailer`] test double (lettre's own error
    /// types cannot be constructed outside its crate).
    #[error("mock mailer: injected send failure")]
    MockFailure,
}

/// Outbound email. Implementations translate to SMTP submission, the
/// console, or a test capture. Object-safe: the process holds one as a
/// `Box<dyn Mailer>` global.
#[async_trait]
pub trait Mailer: Send + Sync {
    /// Send a single message. `body` is plain text.
    async fn send(&self, to: &str, subject: &str, body: &str) -> Result<(), MailerError>;
}

/// SMTP submission config — the relay + envelope From. All values come
/// from the `edge.env` SMTP_* secrets; `from` defaults to
/// `accounts@{root_domain}` when MAIL_FROM is absent.
#[derive(Debug, Clone)]
pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub from: String,
}

impl SmtpConfig {
    /// Resolve from the boot secrets. Returns `None` when no relay is
    /// configured (SMTP_HOST absent) — the caller falls back to the
    /// console mailer. Note: touches the boot-only [`secret::SECRETS`],
    /// so tests construct the config directly instead.
    pub fn from_secrets() -> Option<Self> {
        let host = secret::smtp_host()?.to_string();
        let port = secret::smtp_port()
            .and_then(|p| p.parse().ok())
            .unwrap_or(587);
        Some(Self {
            host,
            port,
            username: secret::smtp_user().unwrap_or_default().to_string(),
            password: secret::smtp_pass().unwrap_or_default().to_string(),
            from: secret::mail_from(),
        })
    }
}

/// Build the MIME message. Pure — unit-testable without a relay.
pub fn message_for(from: &str, to: &str, subject: &str, body: &str) -> Result<Message, MailerError> {
    Ok(Message::builder()
        .from(from.parse()?)
        .to(to.parse()?)
        .subject(subject)
        .header(ContentType::TEXT_PLAIN)
        .body(body.to_string())?)
}

/// Sends via the relay's SMTP submission port (STARTTLS + AUTH). The
/// transport is built lazily — no network happens until [`send`], so
/// construction is testable without a live relay.
pub struct SmtpMailer {
    from: String,
    transport: AsyncSmtpTransport<Tokio1Executor>,
}

impl SmtpMailer {
    pub fn new(config: SmtpConfig) -> Result<Self, MailerError> {
        let transport = AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&config.host)?
            .port(config.port)
            .credentials(Credentials::new(config.username, config.password))
            .build();
        Ok(Self {
            from: config.from,
            transport,
        })
    }
}

#[async_trait]
impl Mailer for SmtpMailer {
    async fn send(&self, to: &str, subject: &str, body: &str) -> Result<(), MailerError> {
        let email = message_for(&self.from, to, subject, body)?;
        self.transport.send(email).await?;
        Ok(())
    }
}

/// Prints the message to stdout (dev/test/L2 when no relay is
/// configured). The magic link shows up in the boot log; the L2 test
/// parses it.
pub struct ConsoleMailer;

#[async_trait]
impl Mailer for ConsoleMailer {
    async fn send(&self, to: &str, subject: &str, body: &str) -> Result<(), MailerError> {
        tracing::info!(to, subject, "console mailer");
        println!("[cococoir-mailer] to={to} subject={subject}\n{body}");
        Ok(())
    }
}

/// A message the [`MockMailer`] captured.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SentMail {
    pub to: String,
    pub subject: String,
    pub body: String,
}

/// Test capture: records every send so tests assert recipient + the
/// magic-link token. No I/O, never fails — unless [`fail_sends`] was
/// set, which simulates a relay outage so tests exercise the
/// send-failure rollback path.
#[derive(Debug, Default)]
pub struct MockMailer {
    sent: Mutex<Vec<SentMail>>,
    fail: std::sync::atomic::AtomicBool,
}

impl MockMailer {
    pub fn new() -> Self {
        Self::default()
    }

    /// All messages sent so far, in order.
    pub fn sent(&self) -> Vec<SentMail> {
        self.sent.lock().expect("mock mailer lock").clone()
    }

    /// Make subsequent `send` calls return `MockFailure` (relay outage).
    pub fn fail_sends(&self) {
        self.fail
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

#[async_trait]
impl Mailer for MockMailer {
    async fn send(&self, to: &str, subject: &str, body: &str) -> Result<(), MailerError> {
        if self.fail.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(MailerError::MockFailure);
        }
        self.sent.lock().expect("mock mailer lock").push(SentMail {
            to: to.to_string(),
            subject: subject.to_string(),
            body: body.to_string(),
        });
        Ok(())
    }
}

/// Pick the mailer for a resolved SMTP config: console when absent,
/// SMTP when present (a broken config is `Err`, never a fallback).
pub fn mailer_for(config: Option<SmtpConfig>) -> Result<Box<dyn Mailer>, MailerError> {
    match config {
        Some(config) => Ok(Box::new(SmtpMailer::new(config)?)),
        None => Ok(Box::new(ConsoleMailer)),
    }
}

/// Resolve the mailer from the boot secrets. Console when SMTP_HOST is
/// absent; a configured-but-broken relay fails loudly at boot.
pub fn mailer_from_secrets() -> Result<Box<dyn Mailer>, MailerError> {
    mailer_for(SmtpConfig::from_secrets())
}

/// The process mailer, initialized once by `init_globals` from the boot
/// secrets. The HTTP layer reads it via [`mailer`]; the account logic
/// takes a `&dyn Mailer` parameter instead so tests inject a mock.
static MAILER: tokio::sync::OnceCell<Box<dyn Mailer>> = tokio::sync::OnceCell::const_new();

/// The process mailer. Panics if `init_globals` never ran.
pub fn mailer() -> &'static dyn Mailer {
    MAILER.get().expect("mailer not initialized").as_ref()
}

/// The process mailer, or `None` before [`init_mailer`] ran. Lets
/// callers mount mail-dependent routes only when it exists (the web
/// routes), without forcing a panic during tests that never initialize
/// the process globals.
pub fn mailer_opt() -> Option<&'static dyn Mailer> {
    MAILER.get().map(|boxed| boxed.as_ref())
}

/// Initialize the process mailer from the boot secrets. A
/// configured-but-broken relay fails boot (a config error is never a
/// silent fallback to the console mailer).
pub fn init_mailer() -> Result<(), MailerError> {
    let _ = MAILER.set(mailer_from_secrets()?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn smtp_config() -> SmtpConfig {
        SmtpConfig {
            host: "relay.example.com".to_string(),
            port: 587,
            username: "bob".to_string(),
            password: "sekrit".to_string(),
            from: "accounts@example.com".to_string(),
        }
    }

    #[test]
    fn message_for_builds_expected_headers() {
        let msg = message_for("accounts@example.com", "alice@example.com", "Verify", "link").unwrap();
        assert_eq!(msg.envelope().from().unwrap().to_string(), "accounts@example.com");
        assert_eq!(msg.envelope().to()[0].to_string(), "alice@example.com");
        let headers = msg.headers().to_string();
        assert!(headers.contains("Subject: Verify"), "headers: {headers}");
        assert!(
            headers.contains("Content-Type: text/plain"),
            "headers: {headers}"
        );
    }

    #[test]
    fn message_for_rejects_bad_address() {
        assert!(message_for("not-an-address", "alice@example.com", "s", "b").is_err());
        assert!(message_for("accounts@example.com", "also-not-valid", "s", "b").is_err());
    }

    #[test]
    fn smtp_mailer_builds_starttls_auth_transport() {
        // Build is lazy — no network. Construction success proves the
        // config maps onto a STARTTLS+AUTH transport.
        let mailer = SmtpMailer::new(smtp_config()).unwrap();
        assert_eq!(mailer.from, "accounts@example.com");
    }

    #[tokio::test]
    async fn mock_mailer_records_recipient_and_body() {
        let mailer = MockMailer::new();
        for i in 0..3 {
            let to = format!("user{i}@example.com");
            let body = format!("token-{i}");
            mailer.send(&to, "Verify", &body).await.unwrap();
        }
        let sent = mailer.sent();
        assert_eq!(sent.len(), 3);
        assert_eq!(sent[0].to, "user0@example.com");
        assert_eq!(sent[0].subject, "Verify");
        assert!(sent[0].body.contains("token-0"));
        assert!(sent[2].body.contains("token-2"));
    }

    #[test]
    fn mailer_for_builds_without_network() {
        // Construction is lazy (no dial-out); a send would hit the relay.
        assert!(mailer_for(Some(smtp_config())).is_ok());
        assert!(mailer_for(None).is_ok());
    }
}