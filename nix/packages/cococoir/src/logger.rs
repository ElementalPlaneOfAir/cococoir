// SPDX-License-Identifier: AGPL-3.0-or-later
//! Structured logging setup for the cococoir binaries.
//!
//! Port of Go `internal/logger/logger.go`. The cmd entry points call
//! [`Format::parse`] on their `-log-format` flag, then [`init`] the
//! global tracing subscriber. The `component` attribute is attached
//! to every record via a span entered by the cmd entry point, so the
//! data model (component, msg, key/value attrs) is the same whether
//! the handler is text or JSON.

use std::io;

use thiserror::Error;
use tracing_subscriber::fmt;
use tracing_subscriber::EnvFilter;

/// Structured-logging output format. Use [`Format::parse`] to obtain
/// a `Format` from an operator-supplied string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Text,
    Json,
}

/// Logger setup failure. A misconfigured value fails the binary at
/// startup, not at log time.
#[derive(Debug, Error)]
pub enum LoggerError {
    #[error("logger: unknown format {0:?} (want \"text\" or \"json\")")]
    UnknownFormat(String),
}

impl Format {
    /// Returns the `Format` for `s`, or an error if `s` is not one
    /// of the known formats.
    pub fn parse(s: &str) -> Result<Self, LoggerError> {
        match s {
            "text" => Ok(Format::Text),
            "json" => Ok(Format::Json),
            other => Err(LoggerError::UnknownFormat(other.to_string())),
        }
    }
}

/// Installs the global tracing subscriber writing to stderr at Info
/// level in `format`. Call once at process start. The caller enters a
/// `component` span so every record carries it.
pub fn init(format: Format) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    match format {
        Format::Text => {
            let _ = fmt()
                .with_writer(io::stderr)
                .with_target(false)
                .with_ansi(false)
                .with_env_filter(filter)
                .try_init();
        }
        Format::Json => {
            let _ = fmt()
                .with_writer(io::stderr)
                .with_target(false)
                .with_ansi(false)
                .json()
                .with_env_filter(filter)
                .try_init();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_text_and_json() {
        assert_eq!(Format::parse("text").unwrap(), Format::Text);
        assert_eq!(Format::parse("json").unwrap(), Format::Json);
    }

    #[test]
    fn parse_rejects_unknown() {
        let err = Format::parse("yaml").unwrap_err();
        assert!(err.to_string().contains("yaml"));
    }
}
