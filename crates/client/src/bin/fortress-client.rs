// SPDX-License-Identifier: AGPL-3.0-or-later
//! fortress-client: the customer box's single process — the L4
//! TCP/UDP forwarder that receives traffic from fortress-edge over
//! WireGuard and forwards to 127.0.0.1:<port> where local Caddy
//! terminates TLS, plus the embedded config dashboard. Pure L4; the
//! Caddy on the customer's box owns TLS. See PLAN.md ADR-006.
#![deny(unsafe_code)]

#[tokio::main]
async fn main() {
    std::process::exit(
        fortress_client::app::run("fortress-client", "/etc/fortress-client.json").await,
    );
}
