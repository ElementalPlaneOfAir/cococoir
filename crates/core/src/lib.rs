// SPDX-License-Identifier: AGPL-3.0-or-later
//! cococoir-core — the shared L4 TCP/UDP forwarder engine.
//!
//! The two product systems (`cococoir-edge`, `cococoir-client`) are
//! built on this crate: it holds the forwarder, the health/status
//! server, and the small shared plumbing (logger, bind retry). It has
//! no binaries and consumes no secrets.

pub mod forwarder;
pub mod health;
pub mod logger;
mod retry;
mod tcp;
mod udp;
pub mod wg;
