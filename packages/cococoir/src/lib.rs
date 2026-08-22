// SPDX-License-Identifier: AGPL-3.0-or-later
//! cococoir v2 — Rust L4 TCP/UDP forwarder.
//!
//! The shared forwarder used by both `cococoir-edge` (VPS) and
//! `cococoir-client` (customer box). The two binaries are thin
//! wrappers around this crate: they parse a JSON config of
//! `{forwards: [{listen_addr, proto, dest_addr}, ...]}` and hand
//! the slice to a `Forwarder`.
//!
//! Replaces the v0 Go module (`nix/packages/cococoir`). See
//! `.specify/specs/rust-forwarder-port/proposal.md`.

pub mod app;
pub mod controlplane;
pub mod dashboard;
pub mod forwarder;
pub mod health;
mod logger;
mod retry;
mod tcp;
mod udp;
