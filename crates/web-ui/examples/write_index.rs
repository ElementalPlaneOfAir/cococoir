// SPDX-License-Identifier: AGPL-3.0-or-later
// Regenerates crates/site/public/index.html from the zine shell. Run
// from the repo root:
//   cargo run -p fortress-web-ui --example write_index \
//     > crates/site/public/index.html
// Then add the wasm client script line before </body> (the tripwire
// test in the site crate asserts the exact expected bytes).
fn main() {
    print!(
        "{}",
        fortress_web_ui::index_shell_html("Fortress — your home server, your rules")
    );
}
