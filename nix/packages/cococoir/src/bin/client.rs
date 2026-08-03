// SPDX-License-Identifier: AGPL-3.0-or-later
//! cococoir-client: customer-box-side L4 TCP/UDP forwarder. Receives
//! traffic from cococoir-edge over WireGuard and forwards to
//! 127.0.0.1:<port> where local Caddy terminates TLS. Pure L4; the
//! Caddy on the customer's box owns TLS. See PLAN.md ADR-006.
#![deny(unsafe_code)]

#[tokio::main]
async fn main() {
    std::process::exit(
        cococoir::app::run("cococoir-client", "/etc/cococoir-client.json").await,
    );
}
