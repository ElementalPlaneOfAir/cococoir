// SPDX-License-Identifier: AGPL-3.0-or-later
//! Dev tool: render the controlplane auth + dashboard pages to static
//! HTML files for preview and screenshots, without the edge (no Redis,
//! no secrets). Writes one file per page under the directory in argv[1]
//! (default `target/auth-preview`).
//!
//!     cargo run -p fortress-controlplane --example auth_preview -- /tmp/auth
use fortress_controlplane::controlplane::web::{
    ForgotOutcome, ForgotPage, ForgotProps, JoinPage, JoinProps, LoginPage, LoginProps,
    MachinesPage, MachinesProps, MessagePage, MessageProps, MsgKind, ResetPage, ResetProps,
    ResendPage, ResendPageProps, SignupPage, SignupProps, VerifyNoticePage, VerifyNoticeProps,
    VerifyPage, VerifyProps,
};
use fortress_controlplane::controlplane::{InviteRecord, InviteStatus, Machine};
use momenta::prelude::*;

fn write(dir: &std::path::Path, name: &str, html: String) {
    let path = dir.join(name);
    std::fs::write(&path, html).expect("write preview html");
    println!("wrote {}", path.display());
}

fn main() {
    let out = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "target/auth-preview".to_string());
    let dir = std::path::Path::new(&out);
    std::fs::create_dir_all(dir).expect("create preview dir");

    let preview: Vec<(&str, String)> = vec![
        (
            "signup.html",
            component::<SignupPage>(SignupProps {
                email: "nicole@example.com".into(),
                error: None,
            })
            .to_html(),
        ),
        (
            "login.html",
            component::<LoginPage>(LoginProps {
                email: "nicole@example.com".into(),
                error: Some("Incorrect email or password.".into()),
            })
            .to_html(),
        ),
        (
            "machines.html",
            component::<MachinesPage>(MachinesProps {
                email: "nicole@example.com".into(),
                machines: vec![Machine {
                    name: "living-room".into(),
                    owner: None,
                    hostname: "living-room".into(),
                    ipv6: String::new(),
                    wg_ip: String::new(),
                    wg_public_key: "base64key=".into(),
                    device_token_hash: Some(String::new()),
                }],
                invites: vec![(
                    "CODE-1234".into(),
                    InviteRecord {
                        owner_email: "nicole@example.com".into(),
                        status: InviteStatus::Waiting,
                        device_pubkey: Some("candidatebase64key=".into()),
                    },
                )],
                invited_code: Some("CODE-1234".into()),
                error: None,
                root_domain: "fortress.example".into(),
            })
            .to_html(),
        ),
        (
            "forgot-prompt.html",
            component::<ForgotPage>(ForgotProps {
                outcome: ForgotOutcome::Prompt,
            })
            .to_html(),
        ),
        (
            "message.html",
            component::<MessagePage>(MessageProps {
                kind: MsgKind::Ok,
                title: "Email verified".into(),
                message: "Your email is verified. You can log in now.".into(),
            })
            .to_html(),
        ),
        (
            "join.html",
            component::<JoinPage>(JoinProps {
                code: "CODE-1234".into(),
            })
            .to_html(),
        ),
        (
            "verify.html",
            component::<VerifyPage>(VerifyProps {
                token: "tok".into(),
            })
            .to_html(),
        ),
        (
            "reset.html",
            component::<ResetPage>(ResetProps {
                token: "tok".into(),
                error: None,
            })
            .to_html(),
        ),
    ];
    for (name, html) in preview {
        write(dir, name, html);
    }
}
