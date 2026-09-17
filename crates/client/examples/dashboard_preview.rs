// SPDX-License-Identifier: AGPL-3.0-or-later
//! Dev tool: render the local dashboard's pages to static HTML files for
//! preview and screenshots, without the box (no sqlite, no auth).
//! Writes one file per page under the directory in argv[1] (default
//! `target/dashboard-preview`).
//!
//!     cargo run -p fortress-client --example dashboard_preview -- /tmp/dash
use fortress_client::dashboard::components::{
    EditorPage, EditorPageProps, EditorServiceProps, EditorUserProps, IndexPage, IndexProps,
    LoginPage, LoginPageProps,
};
use momenta::prelude::*;

fn main() {
    let out = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "target/dashboard-preview".to_string());
    let dir = std::path::Path::new(&out);
    std::fs::create_dir_all(dir).expect("create preview dir");

    let pages: Vec<(&str, String)> = vec![
        (
            "login.html",
            component::<LoginPage>(LoginPageProps { error: false }).to_html(),
        ),
        (
            "index.html",
            component::<IndexPage>(IndexProps {
                name: "nicole".into(),
                count: 3,
            })
            .to_html(),
        ),
        (
            "editor.html",
            component::<EditorPage>(EditorPageProps {
                hostname: "living-room".into(),
                base_domain: "nicole.example.com".into(),
                services: vec![
                    EditorServiceProps {
                        nixname: "jellyfin".into(),
                        display_name: "Jellyfin",
                        description: "Media server",
                        enabled: true,
                        declared: true,
                    },
                    EditorServiceProps {
                        nixname: "cryptpad".into(),
                        display_name: "CryptPad",
                        description: "Collaborative docs",
                        enabled: false,
                        declared: false,
                    },
                ],
                users: vec![EditorUserProps {
                    username: "nicole".into(),
                    is_admin: true,
                    groups: vec!["media".into()],
                    has_password: true,
                    groups_declared: true,
                }],
                config_error: None,
                saved: false,
                save_error: None,
            })
            .to_html(),
        ),
    ];
    for (name, html) in pages {
        let path = dir.join(name);
        std::fs::write(&path, html).expect("write preview html");
        println!("wrote {}", path.display());
    }
}
