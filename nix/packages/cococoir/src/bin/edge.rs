// SPDX-License-Identifier: AGPL-3.0-or-later
//! cococoir-edge: VPS-side L4 TCP/UDP forwarder. Receives traffic on
//! public IPs and forwards over WireGuard to the customer box where
//! cococoir-client hands it to local services. Pure L4; TLS lives on
//! the customer's box (Caddy), not on the cococoir data path. See
//! PLAN.md ADR-006.
#![deny(unsafe_code)]

#[tokio::main]
async fn main() {
    std::process::exit(
        cococoir::app::run("cococoir-edge", "/etc/cococoir-edge.json").await,
    );
}
