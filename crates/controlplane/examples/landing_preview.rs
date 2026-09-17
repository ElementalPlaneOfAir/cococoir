// SPDX-License-Identifier: AGPL-3.0-or-later
//! Dev tool: render the real `Landing` component to a static HTML file
//! so the marketing page can be previewed and screenshot without the
//! edge (no Redis, no secrets). Writes to the path in argv[1] (default
//! `target/landing.html`). All assets are inlined from the vendored
//! `fortress-web-ui` copies, exactly like production.
//!
//!     cargo run -p fortress-controlplane --example landing_preview -- /tmp/landing.html
use fortress_controlplane::controlplane::web::{Landing, LandingProps};
use momenta::prelude::*;

fn main() {
    let out = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "target/landing.html".to_string());
    let html = component::<Landing>(LandingProps {
        logged_in: false,
        email: None,
    })
    .to_html();
    std::fs::write(&out, html).expect("write landing html");
    println!("wrote {out}");
}
