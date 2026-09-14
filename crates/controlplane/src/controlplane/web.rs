// SPDX-License-Identifier: AGPL-3.0-or-later
//! The customer-facing web UI: landing, signup, login, verify, reset.
//!
//! Served by the edge's merged binary at `{ROOT_DOMAIN}`. Forms post to
//! `/auth/*` so they never collide with the operator OpenAPI routes
//! (`POST /signup` stays the AdminKey JSON endpoint). Sessions are the
//! T2 Redis sessions in an `HttpOnly` + `SameSite=Lax` cookie.
//!
//! Magic links: `GET /verify?token=` does NOT consume the token — it
//! renders a confirmation form that POSTs to `/auth/verify`. This is a
//! deliberate guard against email-client link prefetching, which would
//! otherwise burn a single-use token before the human clicks it. The
//! reset link already follows this shape: `GET /reset?token=` renders
//! the password form; the token is consumed by the `POST /auth/reset`.

use crate::controlplane::account::AccountError;
use crate::controlplane::mail::Mailer;
use crate::controlplane::{AppState, ControlPlane};
use momenta::prelude::*;
use poem::{
    get, handler, post,
    http::{header, HeaderValue, StatusCode},
    web::{Data, Form, Html, Query},
    IntoResponse, Request, Response, Route,
};
use serde::Deserialize;

/// The account session cookie. Distinct from the client dashboard's
/// `fortress_session` (different service, different domain).
pub const SESSION_COOKIE: &str = "fortress_account_session";

/// The injected control plane, or a 500 when the web routes were mounted
/// without one (a test-side bug — production always injects it). The
/// `Err` is a `Response` so handlers can `return resp` directly.
fn cp_or_500(state: &AppState) -> Result<&'static ControlPlane, Response> {
    match state.cp {
        Some(cp) => Ok(cp),
        None => Err(StatusCode::INTERNAL_SERVER_ERROR.into_response()),
    }
}

/// The injected mailer, or a 500 when the web routes were mounted
/// without one (a test-side bug — production always injects it).
fn mailer_or_500(state: &AppState) -> Result<&'static dyn Mailer, Response> {
    match state.mailer {
        Some(mailer) => Ok(mailer),
        None => Err(StatusCode::INTERNAL_SERVER_ERROR.into_response()),
    }
}

fn read_cookie(req: &Request, name: &str) -> Option<String> {
    req.headers()
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .map(str::trim)
        .find_map(|part| {
            let (key, value) = part.split_once('=')?;
            (key == name).then(|| value.to_string())
        })
}

fn session_cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Lax"
    ))
    .expect("session cookie header is valid")
}

fn clear_session_cookie_header() -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
    ))
    .expect("cleared session cookie header is valid")
}

/// The logged-in email for this request, if the session cookie is valid.
async fn session_email(cp: &'static ControlPlane, req: &Request) -> Option<String> {
    let token = read_cookie(req, SESSION_COOKIE)?;
    cp.session_account(&token).await.ok().flatten()
}

// ── pages (momenta + daisyUI, same as the client dashboard) ─────────

/// The custom CSS the landing page needs beyond Tailwind/daisyUI
/// utilities: the radial glow background, gradient headline text, the
/// soft card shadow, and the checkmark list ticks. Injected raw via
/// `_dangerously_set_inner_html` because a `<style>` child would have
/// its `>` and `/` escaped as text.
const LANDING_CSS: &str = r#"
  body {
    background:
      radial-gradient(1200px 600px at 50% -10%, oklch(0.3 0.12 290 / 0.5), transparent 60%),
      radial-gradient(900px 500px at 85% 10%, oklch(0.35 0.1 200 / 0.35), transparent 55%),
      var(--color-base-100);
  }
  .glow-text {
    background: linear-gradient(100deg, var(--color-primary), var(--color-accent) 45%, var(--color-secondary));
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  .card-glow {
    box-shadow: 0 0 0 1px oklch(1 0 0 / 0.06), 0 20px 60px -20px oklch(0 0 0 / 0.6);
  }
  .tick::before {
    content: "✓";
    color: var(--color-success);
    font-weight: 700;
    margin-right: 0.5rem;
  }
"#;

/// The auth pages' shell: a centered, narrow column of forms.
fn page_shell(title: &str, main: Node) -> Node {
    rsx!(
        <html lang="en" data_theme="dark">
            <head>
                <title>{title}</title>
                <meta charset="UTF-8"/>
                <meta name="viewport" content="width=device-width, initial-scale=1"/>
                <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
                <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css"/>
            </head>
            <body class="min-h-screen bg-base-200">
                <main class="mx-auto flex max-w-md flex-col gap-4 p-6">{main}</main>
            </body>
        </html>
    )
}

/// The landing page's shell: full-width, with the custom marketing CSS.
fn landing_shell(main: Node) -> Node {
    rsx!(
        <html lang="en" data_theme="dark">
            <head>
                <title>"Fortress — your home server, your rules"</title>
                <meta charset="UTF-8"/>
                <meta name="viewport" content="width=device-width, initial-scale=1"/>
                <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
                <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css"/>
                <style _dangerously_set_inner_html={LANDING_CSS}></style>
            </head>
            <body class="min-h-screen text-base-content">{main}</body>
        </html>
    )
}

/// A Fortress shield glyph, reused for the nav logo and footer.
fn shield_icon(class: &str) -> Node {
    rsx!(
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke_width="2" class={class}>
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
        </svg>
    )
}

pub struct LandingProps {
    pub logged_in: bool,
    pub email: Option<String>,
}

#[component]
pub fn Landing(props: &LandingProps) -> Node {
    // The navbar's account actions: signed-in shows the email + sign out,
    // otherwise the create-account button.
    let nav_auth = if props.logged_in {
        rsx!(
            <>
                <span class="text-sm text-base-content/60 hidden sm:inline">{props.email.as_deref().unwrap_or("")}</span>
                <a href="/auth/logout" class="btn btn-ghost btn-sm">"Sign out"</a>
            </>
        )
    } else {
        rsx!(<a href="/register" class="btn btn-primary btn-sm">"Create account"</a>)
    };

    // The hero's primary CTA: always the account/order path.
    let hero_cta = if props.logged_in {
        rsx!(<a href="/" class="btn btn-primary btn-lg px-8">"Go to my dashboard"</a>)
    } else {
        rsx!(<a href="/register" class="btn btn-primary btn-lg px-8">"Order a box"</a>)
    };

    landing_shell(rsx!(
        <>
            
            <nav class="navbar sticky top-0 z-40 backdrop-blur-md bg-base-100/70 border-b border-white/5 px-6">
                <div class="flex-1 items-center gap-2">
                    {shield_icon("h-7 w-7 text-primary")}
                    <span class="text-lg font-bold tracking-tight">"Fortress"</span>
                </div>
                <div class="flex-none gap-2">
                    <a href="#install" class="btn btn-ghost btn-sm hidden sm:inline-flex">"Install"</a>
                    {nav_auth}
                </div>
            </nav>

            
            <header class="px-6 pt-20 pb-16 text-center">
                <div class="mx-auto max-w-3xl">
                    <div class="badge badge-outline badge-sm mb-6 gap-2 px-3 py-3">
                        <span class="h-2 w-2 rounded-full bg-success animate-pulse"></span>
                        "A worker cooperative · open source · NixOS"
                    </div>
                    <h1 class="text-5xl sm:text-6xl font-black tracking-tight leading-[1.05]">
                        <span class="block">"Your home server."</span>
                        <span class="block glow-text">"Your data. Your rules."</span>
                    </h1>
                    <p class="mx-auto mt-6 max-w-xl text-lg text-base-content/70">
                        "Fortress replaces Google Docs, Dropbox, Netflix and Ring with a self-hosted box in your house — reachable from anywhere, with every key on your own hardware."
                    </p>
                    <div class="mt-8 flex flex-col sm:flex-row items-center justify-center gap-3">
                        {hero_cta}
                        <a href="#install" class="btn btn-outline btn-lg px-8">"Install it yourself"</a>
                    </div>
                    <div class="mt-12 flex flex-wrap items-center justify-center gap-x-8 gap-y-3 text-sm text-base-content/50">
                        <span>"Own your data"</span>
                        <span class="text-base-content/20">"•"</span>
                        <span>"Remote access built in"</span>
                        <span class="text-base-content/20">"•"</span>
                        <span>"One login for everything"</span>
                        <span class="text-base-content/20">"•"</span>
                        <span>"No subscription lock-in"</span>
                    </div>
                </div>
            </header>

            
            <section class="px-6 py-10">
                <div class="mx-auto max-w-5xl">
                    <div class="flex flex-wrap items-center justify-center gap-3">
                        <span class="text-sm text-base-content/50 mr-2">"Replaces:"</span>
                        <div class="flex flex-wrap justify-center gap-3">
                            <span class="px-4 py-2 rounded-xl bg-base-200/60 text-sm">"Google Docs → " <b class="text-success">"CryptPad"</b></span>
                            <span class="px-4 py-2 rounded-xl bg-base-200/60 text-sm">"Netflix → " <b class="text-success">"Jellyfin"</b></span>
                            <span class="px-4 py-2 rounded-xl bg-base-200/60 text-sm">"+ Radarr, Sonarr, Lidarr, Prowlarr"</span>
                            <span class="px-4 py-2 rounded-xl bg-base-200/60 text-sm">"Nextcloud" <b class="badge badge-sm badge-outline ml-1">"soon"</b></span>
                        </div>
                    </div>
                </div>
            </section>

            
            <section class="px-6 py-14">
                <div class="mx-auto max-w-5xl">
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-5">
                        <div class="card bg-base-200/50 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke_width="2" class="h-8 w-8 text-primary"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg>
                                <h3 class="card-title text-lg">"Your keys, your hardware"</h3>
                                <p class="text-sm text-base-content/60">"TLS and WireGuard keys never leave your house. Nobody else can decrypt your traffic — not even us."</p>
                            </div>
                        </div>
                        <div class="card bg-base-200/50 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke_width="2" class="h-8 w-8 text-accent"><circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
                                <h3 class="card-title text-lg">"Reachable anywhere"</h3>
                                <p class="text-sm text-base-content/60">"One encrypted tunnel to a box in the cloud. Jellyfin, docs, photos — from any phone, on any network, no port forwarding."</p>
                            </div>
                        </div>
                        <div class="card bg-base-200/50 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke_width="2" class="h-8 w-8 text-secondary"><path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/></svg>
                                <h3 class="card-title text-lg">"One login for everything"</h3>
                                <p class="text-sm text-base-content/60">"Every service signs in with the same account. Add a user once, they get every app — no per-app password sprawl."</p>
                            </div>
                        </div>
                    </div>
                </div>
            </section>

            
            <section class="px-6 py-14">
                <div class="mx-auto max-w-5xl">
                    <h2 class="text-center text-3xl font-bold mb-10">"Two ways in"</h2>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
                        <div class="card bg-base-100 border border-white/5 card-glow">
                            <div class="card-body gap-4">
                                <div class="badge badge-primary badge-sm w-fit">"Zero setup"</div>
                                <h3 class="card-title text-2xl">"Buy a box"</h3>
                                <p class="text-sm text-base-content/60">"We assemble, install and ship a pre-configured Fortress. Plug it in, connect ethernet, and claim it with your account in under five minutes."</p>
                                <ul class="flex flex-col gap-2 text-sm">
                                    <li class="tick">"Pre-installed NixOS + all services"</li>
                                    <li class="tick">"Encrypted offsite backups included"</li>
                                    <li class="tick">"Support from real humans"</li>
                                </ul>
                                <div class="card-actions mt-2"><a href="/register" class="btn btn-primary">"Get yours"</a></div>
                            </div>
                        </div>
                        <div class="card bg-base-100 border border-white/5 card-glow">
                            <div class="card-body gap-4">
                                <div class="badge badge-accent badge-sm w-fit">"Bring your own hardware"</div>
                                <h3 class="card-title text-2xl">"Install on your machine"</h3>
                                <p class="text-sm text-base-content/60">"Fortress is a NixOS module. Point your flake at it, enable the services you want, rebuild. No setup wizard, no app store."</p>
                                <ul class="flex flex-col gap-2 text-sm">
                                    <li class="tick">"Free forever, AGPL-3.0"</li>
                                    <li class="tick">"Run as many machines as you like"</li>
                                    <li class="tick">"Same remote access as a box"</li>
                                </ul>
                                <div class="card-actions mt-2"><a href="#install" class="btn btn-outline">"See the install guide"</a></div>
                            </div>
                        </div>
                    </div>
                </div>
            </section>

            
            <section id="install" class="px-6 py-14 scroll-mt-16">
                <div class="mx-auto max-w-3xl">
                    <h2 class="text-center text-3xl font-bold mb-2">"Install on your own machines"</h2>
                    <p class="text-center text-base-content/60 mb-10">"Runs on any x86-64 NixOS machine. Each machine is one file in your flake."</p>

                    <div class="flex flex-col gap-5">
                        <div class="card bg-base-100 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <div class="flex items-center gap-3">
                                    <span class="badge badge-primary">"1"</span>
                                    <h3 class="card-title">"Add the flake input"</h3>
                                </div>
                                <pre class="rounded-xl bg-neutral p-4 text-xs font-mono overflow-x-auto">{r#"{
  inputs = {
    fortress.url = "github:ElementalPlaneOfAir/cococoir";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}"#}</pre>
                            </div>
                        </div>

                        <div class="card bg-base-100 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <div class="flex items-center gap-3">
                                    <span class="badge badge-primary">"2"</span>
                                    <h3 class="card-title">"Import the module"</h3>
                                </div>
                                <pre class="rounded-xl bg-neutral p-4 text-xs font-mono overflow-x-auto">{r#"{
  imports = [ inputs.fortress.nixosModules.default ];
}"#}</pre>
                            </div>
                        </div>

                        <div class="card bg-base-100 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <div class="flex items-center gap-3">
                                    <span class="badge badge-primary">"3"</span>
                                    <h3 class="card-title">"Enable services and rebuild"</h3>
                                </div>
                                <pre class="rounded-xl bg-neutral p-4 text-xs font-mono overflow-x-auto">{r#"fortress.services.jellyfin = { enable = true; public = true; };
fortress.services.dex      = { enable = true; public = true; };

sudo nixos-rebuild switch --flake .#mybox"#}</pre>
                                <p class="text-sm text-base-content/60">"Each service gets its own Caddy vhost with automatic TLS. Enable a service next to Dex and every user signs in with one account."</p>
                            </div>
                        </div>

                        <div class="card bg-base-100 border border-white/5 card-glow">
                            <div class="card-body gap-3">
                                <div class="flex items-center gap-3">
                                    <span class="badge badge-primary">"4"</span>
                                    <h3 class="card-title">"Repeat per machine"</h3>
                                </div>
                                <p class="text-sm text-base-content/60">"One flake, many machines. Each machine is its own " <code class="text-primary">"nixosConfiguration"</code> " importing the same module — give it a hostname, a " <code class="text-primary">"fortress.baseDomain"</code> ", and enable the services it should run. Storage, TLS and DNS follow automatically."</p>
                                <pre class="rounded-xl bg-neutral p-4 text-xs font-mono overflow-x-auto">{r#"# flake.nix — one module, N machines
outputs = { self, nixpkgs, fortress, ... }: {
  nixosConfigurations = {
    living-room = nixpkgs.lib.nixosSystem {
      modules = [
        fortress.nixosModules.default
        ({ pkgs, ... }: {
          networking.hostName = "living-room";
          fortress.baseDomain = "alice.example.com";
          fortress.services.jellyfin.enable = true;
          fortress.services.dex.enable = true;
        })
      ];
    };
    garage = nixpkgs.lib.nixosSystem {
      modules = [
        fortress.nixosModules.default
        ({ pkgs, ... }: {
          networking.hostName = "garage";
          fortress.baseDomain = "alice.example.com";
          fortress.services.cryptpad.enable = true;
        })
      ];
    };
  };
};"#}</pre>
                                <p class="text-sm text-base-content/60">"Each machine gets its own Caddy vhosts under your domain. Claim them all under one account for a single set of remote-access routes."</p>
                            </div>
                        </div>
                    </div>
                </div>
            </section>

            
            <footer class="px-6 py-12 border-t border-white/5 mt-8">
                <div class="mx-auto max-w-5xl flex flex-col sm:flex-row items-center justify-between gap-4 text-sm text-base-content/50">
                    <div class="flex items-center gap-2">
                        {shield_icon("h-5 w-5 text-primary")}
                        <span>"Fortress — a worker cooperative. AGPL-3.0."</span>
                    </div>
                    <div class="flex items-center gap-4">
                        <a href="/register" class="link link-hover">"Create account"</a>
                        <a href="/login" class="link link-hover">"Sign in"</a>
                    </div>
                </div>
            </footer>
        </>
    ))
}

pub struct SignupProps {
    pub email: String,
    pub username: String,
    pub error: Option<String>,
}

#[component]
pub fn SignupPage(props: &SignupProps) -> Node {
    let banner = match &props.error {
        Some(message) => rsx!(<div role="alert" class="alert alert-error"><span>{message}</span></div>),
        None => Node::Empty,
    };
    page_shell(
        "Create an account",
        rsx!(
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h1 class="card-title text-2xl">"Create an account"</h1>
                    {banner}
                    <form method="post" action="/auth/signup" class="flex flex-col gap-4">
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"Email"</span></div>
                            <input type="email" name="email" value={&props.email} required class="input input-bordered"/>
                        </label>
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"Username"</span></div>
                            <input type="text" name="username" value={&props.username} required class="input input-bordered"/>
                            <div class="label"><span class="label-text text-xs text-base-content/50">"Lowercase letters, digits and hyphens — your devices live at username.example.com."</span></div>
                        </label>
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"Password"</span></div>
                            <input type="password" name="password" required class="input input-bordered"/>
                        </label>
                        <button type="submit" class="btn btn-primary">"Sign up"</button>
                    </form>
                    <p class="text-sm text-base-content/60">
                        "Already have an account? "
                        <a href="/login" class="link">"Log in"</a>
                    </p>
                </div>
            </div>
        ),
    )
}

pub struct LoginProps {
    pub email: String,
    pub error: Option<String>,
}

#[component]
pub fn LoginPage(props: &LoginProps) -> Node {
    let banner = match &props.error {
        Some(message) => rsx!(<div role="alert" class="alert alert-error"><span>{message}</span></div>),
        None => Node::Empty,
    };
    page_shell(
        "Log in",
        rsx!(
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h1 class="card-title text-2xl">"Log in"</h1>
                    {banner}
                    <form method="post" action="/auth/login" class="flex flex-col gap-4">
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"Email"</span></div>
                            <input type="email" name="email" value={&props.email} required class="input input-bordered"/>
                        </label>
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"Password"</span></div>
                            <input type="password" name="password" required class="input input-bordered"/>
                        </label>
                        <button type="submit" class="btn btn-primary">"Log in"</button>
                    </form>
                    <p class="text-sm text-base-content/60">
                        <a href="/forgot" class="link">"Forgot your password?"</a>
                    </p>
                </div>
            </div>
        ),
    )
}

pub enum MsgKind {
    Ok,
    Err,
}

pub struct MessageProps {
    pub kind: MsgKind,
    pub title: String,
    pub message: String,
}

#[component]
pub fn MessagePage(props: &MessageProps) -> Node {
    let (alert_class, icon) = match props.kind {
        MsgKind::Ok => ("alert-success", "✓"),
        MsgKind::Err => ("alert-error", "✗"),
    };
    page_shell(
        &props.title,
        rsx!(
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h1 class="card-title text-2xl">{&props.title}</h1>
                    <div role="alert" class={"alert ".to_string() + alert_class}>
                        <span>{icon} {&props.message}</span>
                    </div>
                    <a href="/" class="btn btn-outline">"Go home"</a>
                </div>
            </div>
        ),
    )
}

pub struct ForgotProps {
    pub sent: bool,
}

#[component]
pub fn ForgotPage(props: &ForgotProps) -> Node {
    if props.sent {
        return page_shell(
            "Check your email",
            rsx!(
                <div class="card bg-base-100 shadow-sm">
                    <div class="card-body flex flex-col gap-4">
                        <h1 class="card-title text-2xl">"Check your email"</h1>
                        <p class="text-base-content/60">"If that email has an account, a reset link is on its way. It expires in 24 hours."</p>
                        <a href="/login" class="btn btn-primary">"Back to login"</a>
                    </div>
                </div>
            ),
        );
    }
    page_shell(
        "Reset your password",
        rsx!(
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h1 class="card-title text-2xl">"Reset your password"</h1>
                    <form method="post" action="/auth/forgot" class="flex flex-col gap-4">
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"Email"</span></div>
                            <input type="email" name="email" required class="input input-bordered"/>
                        </label>
                        <button type="submit" class="btn btn-primary">"Send reset link"</button>
                    </form>
                </div>
            </div>
        ),
    )
}

pub struct ResetProps {
    pub token: String,
    pub error: Option<String>,
}

#[component]
pub fn ResetPage(props: &ResetProps) -> Node {
    let banner = match &props.error {
        Some(message) => rsx!(<div role="alert" class="alert alert-error"><span>{message}</span></div>),
        None => Node::Empty,
    };
    page_shell(
        "Choose a new password",
        rsx!(
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h1 class="card-title text-2xl">"Choose a new password"</h1>
                    {banner}
                    <form method="post" action="/auth/reset" class="flex flex-col gap-4">
                        <input type="hidden" name="token" value={&props.token}/>
                        <label class="form-control w-full">
                            <div class="label"><span class="label-text">"New password"</span></div>
                            <input type="password" name="password" required class="input input-bordered"/>
                        </label>
                        <button type="submit" class="btn btn-primary">"Set password"</button>
                    </form>
                </div>
            </div>
        ),
    )
}

// ── form bodies ────────────────────────────────────────────────────

#[derive(Debug, Default, Deserialize)]
struct SignupForm {
    email: Option<String>,
    username: Option<String>,
    password: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct LoginForm {
    email: Option<String>,
    password: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct ForgotForm {
    email: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct ResetForm {
    token: Option<String>,
    password: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct VerifyForm {
    token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TokenQuery {
    token: Option<String>,
}

// ── handlers ───────────────────────────────────────────────────────

#[handler]
async fn landing(Data(state): Data<&AppState>, req: &Request) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    let email = session_email(cp, req).await;
    Html(component::<Landing>(LandingProps {
        logged_in: email.is_some(),
        email,
    })
    .to_html())
    .into_response()
}

#[handler]
async fn signup_page() -> Response {
    Html(component::<SignupPage>(SignupProps {
        email: String::new(),
        username: String::new(),
        error: None,
    })
    .to_html())
    .into_response()
}

#[handler]
async fn signup(
    Data(state): Data<&AppState>,

    Form(form): Form<SignupForm>,
) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    let mailer = match mailer_or_500(state) { Ok(mailer) => mailer, Err(resp) => return resp };
    let email = form.email.clone().unwrap_or_default();
    let username = form.username.clone().unwrap_or_default();
    let error = match (form.email.as_deref(), form.username.as_deref(), form.password.as_deref()) {
        (Some(email), Some(username), Some(password)) => {
            cp.account_signup(email, username, password, mailer).await.err()
        }
        _ => Some(AccountError::InvalidEmail(email.clone())),
    };
    match error {
        Some(err) => Html(component::<SignupPage>(SignupProps {
            email,
            username,
            error: Some(account_error_message(&err)),
        })
        .to_html())
        .into_response(),
        None => Html(
            component::<MessagePage>(MessageProps {
                kind: MsgKind::Ok,
                title: "Check your email".into(),
                message: format!("A verification link was sent to {email}. It expires in 24 hours."),
            })
            .to_html(),
        )
        .into_response(),
    }
}

#[handler]
async fn login_page() -> Response {
    Html(component::<LoginPage>(LoginProps {
        email: String::new(),
        error: None,
    })
    .to_html())
    .into_response()
}

#[handler]
async fn login(
    Data(state): Data<&AppState>,
    Form(form): Form<LoginForm>,
) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    let email = form.email.clone().unwrap_or_default();
    let result = match (form.email.as_deref(), form.password.as_deref()) {
        (Some(email), Some(password)) => cp.account_login(email, password).await,
        _ => Err(AccountError::InvalidCredentials),
    };
    match result {
        Err(err) => Html(component::<LoginPage>(LoginProps {
            email,
            error: Some(account_error_message(&err)),
        })
        .to_html())
        .into_response(),
        Ok(token) => Response::builder()
            .status(StatusCode::SEE_OTHER)
            .header(header::LOCATION, "/")
            .header(header::SET_COOKIE, session_cookie_header(&token))
            .finish(),
    }
}

#[handler]
async fn logout(Data(state): Data<&AppState>, req: &Request) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    if let Some(token) = read_cookie(req, SESSION_COOKIE) {
        let _ = cp.account_logout(&token).await;
    }
    Response::builder()
        .status(StatusCode::SEE_OTHER)
        .header(header::LOCATION, "/")
        .header(header::SET_COOKIE, clear_session_cookie_header())
        .finish()
}

#[handler]
async fn verify(Query(query): Query<TokenQuery>) -> Response {
    let Some(token) = query.token else {
        return Html(
            component::<MessagePage>(MessageProps {
                kind: MsgKind::Err,
                title: "Missing token".into(),
                message: "This link is invalid or has expired. Try requesting a new one.".into(),
            })
            .to_html(),
        )
        .into_response();
    };
    // Deliberately NOT consumed here — an email-client prefetch of this
    // GET must not burn the single-use token. The confirm button POSTs
    // to /auth/verify to consume it.
    Html(
        component::<VerifyPage>(VerifyProps { token }).to_html(),
    )
    .into_response()
}

pub struct VerifyProps {
    pub token: String,
}

#[component]
pub fn VerifyPage(props: &VerifyProps) -> Node {
    page_shell(
        "Confirm your email",
        rsx!(
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h1 class="card-title text-2xl">"Confirm your email"</h1>
                    <form method="post" action="/auth/verify" class="flex flex-col gap-4">
                        <input type="hidden" name="token" value={&props.token}/>
                        <button type="submit" class="btn btn-primary">"Confirm email"</button>
                    </form>
                </div>
            </div>
        ),
    )
}

#[handler]
async fn verify_confirm(
    Data(state): Data<&AppState>,
    Form(form): Form<VerifyForm>,
) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    let Some(token) = form.token.as_deref() else {
        return message_response(MsgKind::Err, "Verification failed", "This link is invalid or has expired.");
    };
    match cp.account_verify(token).await {
        Ok(()) => message_response(MsgKind::Ok, "Email verified", "Your email is verified. You can log in now."),
        Err(err) => message_response(MsgKind::Err, "Verification failed", &account_error_message(&err)),
    }
}

#[handler]
async fn forgot_page() -> Response {
    Html(component::<ForgotPage>(ForgotProps { sent: false })
        .to_html())
    .into_response()
}

#[handler]
async fn forgot(
    Data(state): Data<&AppState>,

    Form(form): Form<ForgotForm>,
) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    let mailer = match mailer_or_500(state) { Ok(mailer) => mailer, Err(resp) => return resp };
    // No account enumeration: the response is identical whether or not
    // the email has an account.
    if let Some(email) = form.email.as_deref() {
        let _ = cp.request_password_reset(email, mailer).await;
    }
    Html(component::<ForgotPage>(ForgotProps { sent: true })
        .to_html())
    .into_response()
}

#[handler]
async fn reset_page(Query(query): Query<TokenQuery>) -> Response {
    let Some(token) = query.token else {
        return message_response(MsgKind::Err, "Invalid link", "This link is invalid or has expired.");
    };
    Html(component::<ResetPage>(ResetProps {
        token,
        error: None,
    })
    .to_html())
    .into_response()
}

#[handler]
async fn reset(
    Data(state): Data<&AppState>,
    Form(form): Form<ResetForm>,
) -> Response {

    let cp = match cp_or_500(state) { Ok(cp) => cp, Err(resp) => return resp };
    let Some(token) = form.token.as_deref() else {
        return message_response(MsgKind::Err, "Invalid link", "This link is invalid or has expired.");
    };
    let error = match form.password.as_deref() {
        Some(password) => cp.reset_password(token, password).await.err(),
        None => Some(AccountError::InvalidPassword("empty".into())),
    };
    match error {
        Some(err) => Html(component::<ResetPage>(ResetProps {
            token: token.to_string(),
            error: Some(account_error_message(&err)),
        })
        .to_html())
        .into_response(),
        None => message_response(MsgKind::Ok, "Password changed", "Your password is updated. Log in with it now."),
    }
}

// ── helpers ────────────────────────────────────────────────────────

fn message_response(kind: MsgKind, title: &str, message: &str) -> Response {
    Html(
        component::<MessagePage>(MessageProps {
            kind,
            title: title.to_string(),
            message: message.to_string(),
        })
        .to_html(),
    )
    .into_response()
}

/// Map an account error to a customer-facing message. Login failures are
/// generic (no account enumeration); everything else is specific. Shared
/// with the `/api/users` handlers (mod.rs), which map the same error to
/// a status code + this message body.
pub(crate) fn account_error_message(err: &AccountError) -> String {
    match err {
        AccountError::InvalidEmail(_) => "That email address doesn't look valid.".into(),
        AccountError::InvalidUsername(_) => "That username isn't valid — use lowercase letters, digits and hyphens.".into(),
        AccountError::InvalidPassword(_) => "That password is invalid (must not be empty or longer than 72 bytes).".into(),
        AccountError::DuplicateEmail(_) => "An account with that email already exists.".into(),
        AccountError::DuplicateUsername(_) => "That username is already taken.".into(),
        AccountError::NotFound => "Something went wrong with that account.".into(),
        AccountError::InvalidCredentials => "Incorrect email or password.".into(),
        AccountError::NotVerified(_) => "Verify your email first — check your inbox for the confirmation link.".into(),
        AccountError::InvalidToken => "This link is invalid or has expired.".into(),
        AccountError::Corrupt(_) => "Something went wrong on our side. Please try again.".into(),
        AccountError::Redis(_) => "Something went wrong on our side. Please try again.".into(),
        AccountError::Mail(_) => "We couldn't send that email right now. Please try again.".into(),
    }
}

/// The web routes. Mounted into the edge's app with the process
/// `ControlPlane` + `Mailer` injected as poem `Data`.
pub fn web_routes() -> Route {
    Route::new()
        .at("/", get(landing))
        .at("/register", get(signup_page))
        .at("/login", get(login_page))
        .at("/forgot", get(forgot_page))
        .at("/reset", get(reset_page))
        .at("/verify", get(verify))
        .at("/auth/signup", post(signup))
        .at("/auth/login", post(login))
        .at("/auth/logout", get(logout))
        .at("/auth/forgot", post(forgot))
        .at("/auth/reset", post(reset))
        .at("/auth/verify", post(verify_confirm))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::controlplane::dns::MockDnsApiClient;
    use crate::controlplane::mail::MockMailer;
    use crate::controlplane::wg::MockWgClient;
    use crate::controlplane::{Subnet64, WgSubnet};
    use poem::http::StatusCode;
    use poem::test::TestClient;
    use poem::{Endpoint, EndpointExt};

    fn redis_url() -> Option<String> {
        match std::env::var("REDIS_URL") {
            Ok(url) if !url.is_empty() => Some(url),
            _ => None,
        }
    }

    /// Build the test app with injected (not global) ControlPlane +
    /// mailer, so web tests never fight `redis_store_round_trip` over
    /// the process singletons.
    fn test_app(cp: &'static ControlPlane, mailer: &'static dyn Mailer) -> impl Endpoint {
        Route::new()
            .nest("/", web_routes())
            .data(AppState { cp: Some(cp), mailer: Some(mailer) })
    }

    fn setup() -> Option<(&'static ControlPlane, &'static MockMailer)> {
        let url = redis_url()?;
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").unwrap();
        let cp = Box::leak(Box::new(
            ControlPlane::with_deps(&url, subnet, wg_subnet, "example.net", "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=", wg, dns)
                .expect("control plane connects"),
        ));
        let mailer: &'static MockMailer = Box::leak(Box::new(MockMailer::new()));
        Some((cp, mailer))
    }

    fn unique_email(label: &str) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{label}-{}-{}@example.com", std::process::id(), nanos)
    }

    fn extract_token(body: &str) -> String {
        let start = body.find("token=").expect("link present") + "token=".len();
        body[start..].lines().next().unwrap().trim().to_string()
    }

    #[test]
    fn cookie_helpers_produce_expected_headers() {
        let set = session_cookie_header("abc").to_str().unwrap().to_string();
        assert!(set.contains("fortress_account_session=abc"));
        assert!(set.contains("HttpOnly"));
        assert!(set.contains("SameSite=Lax"));
        assert!(set.contains("Path=/"));
        let clear = clear_session_cookie_header().to_str().unwrap().to_string();
        assert!(clear.contains("Max-Age=0"));
    }

    #[tokio::test]
    async fn pages_render() {
        let Some((cp, mailer)) = setup() else {
            eprintln!("skipping: REDIS_URL not set");
            return;
        };
        let client = TestClient::new(test_app(cp, mailer));
        for (path, needle) in [
            ("/", "Your home server"),
            ("/register", "Create an account"),
            ("/login", "Log in"),
            ("/forgot", "Reset your password"),
            ("/verify", "This link is invalid or has expired"),
            ("/reset", "This link is invalid or has expired"),
        ] {
            let resp = client.get(path).send().await;
            resp.assert_status(StatusCode::OK);
            let body = resp.0.into_body().into_string().await.unwrap();
            assert!(body.contains(needle), "{path} renders {needle}");
        }
    }

    #[tokio::test]
    async fn signup_verify_login_logout_web_round_trip() {
        let Some((cp, mailer)) = setup() else {
            eprintln!("skipping: REDIS_URL not set");
            return;
        };
        let client = TestClient::new(test_app(cp, mailer));
        let email = unique_email("web");
        let username = email.split('@').next().unwrap().to_string();

        // Signup via the form.
        let resp = client
            .post("/auth/signup")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&username={username}&password=hunter2"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("A verification link was sent"), "shows check-your-email");

        // The mailer captured the magic link.
        let sent = mailer.sent();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].to, email);
        let token = extract_token(&sent[0].body);

        // Login is refused before verification.
        let resp = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&password=hunter2"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Verify your email first"));

        // GET /verify does NOT consume the token (prefetch guard).
        let resp = client.get(format!("/verify?token={token}")).send().await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Confirm email"));

        // POST /auth/verify consumes it.
        let resp = client
            .post("/auth/verify")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("token={token}"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Your email is verified"));

        // Login now issues the session cookie.
        let resp = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&password=hunter2"))
            .send()
            .await;
        resp.assert_status(StatusCode::SEE_OTHER);
        let set_cookie = resp
            .0
            .headers()
            .get(header::SET_COOKIE)
            .expect("session cookie set")
            .to_str()
            .unwrap()
            .to_string();
        assert!(set_cookie.contains("fortress_account_session="));

        // The cookie makes the landing page show the signed-in user.
        let token = set_cookie
            .split("fortress_account_session=")
            .nth(1)
            .and_then(|rest| rest.split(';').next())
            .expect("cookie value");
        let resp = client
            .get("/")
            .header(header::COOKIE, format!("fortress_account_session={token}"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Signed in as"));
        assert!(body.contains(&email));

        // Logout clears the session.
        let resp = client
            .get("/auth/logout")
            .header(header::COOKIE, format!("fortress_account_session={token}"))
            .send()
            .await;
        resp.assert_status(StatusCode::SEE_OTHER);
        assert!(resp
            .0
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap()
            .contains("Max-Age=0"));
        let resp = client.get("/").send().await;
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Create an account"), "logged out landing");
    }

    #[tokio::test]
    async fn reset_web_round_trip_without_session() {
        let Some((cp, mailer)) = setup() else {
            eprintln!("skipping: REDIS_URL not set");
            return;
        };
        let client = TestClient::new(test_app(cp, mailer));
        let email = unique_email("webreset");
        let username = email.split('@').next().unwrap().to_string();

        client
            .post("/auth/signup")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&username={username}&password=old-password"))
            .send()
            .await
            .assert_status(StatusCode::OK);
        let verify_token = extract_token(&mailer.sent()[0].body);
        client
            .post("/auth/verify")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("token={verify_token}"))
            .send()
            .await
            .assert_status(StatusCode::OK);

        // Request a reset via the form — identical message for unknown
        // emails (no enumeration), and the mailer got the link.
        let resp = client
            .post("/auth/forgot")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("If that email has an account"));
        let reset_token = extract_token(&mailer.sent()[1].body);

        // GET /reset renders the form; POST /auth/reset sets the password.
        let resp = client.get(format!("/reset?token={reset_token}")).send().await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Choose a new password"));

        let resp = client
            .post("/auth/reset")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("token={reset_token}&password=new-password"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Your password is updated"));

        // The new password logs in; the old one doesn't.
        let old = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&password=old-password"))
            .send()
            .await;
        let body = old.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Incorrect email or password"));
        client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&password=new-password"))
            .send()
            .await
            .assert_status(StatusCode::SEE_OTHER);
    }

    #[tokio::test]
    async fn wrong_password_renders_error_page() {
        let Some((cp, mailer)) = setup() else {
            eprintln!("skipping: REDIS_URL not set");
            return;
        };
        let client = TestClient::new(test_app(cp, mailer));
        let email = unique_email("webwrong");
        let username = email.split('@').next().unwrap().to_string();
        client
            .post("/auth/signup")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&username={username}&password=hunter2"))
            .send()
            .await
            .assert_status(StatusCode::OK);
        let verify_token = extract_token(&mailer.sent()[0].body);
        client
            .post("/auth/verify")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("token={verify_token}"))
            .send()
            .await
            .assert_status(StatusCode::OK);

        let resp = client
            .post("/auth/login")
            .content_type("application/x-www-form-urlencoded")
            .body(format!("email={email}&password=nope"))
            .send()
            .await;
        resp.assert_status(StatusCode::OK);
        let body = resp.0.into_body().into_string().await.unwrap();
        assert!(body.contains("Incorrect email or password"));
    }

    #[test]
    fn account_error_messages_are_customer_facing() {
        assert_eq!(
            account_error_message(&AccountError::InvalidCredentials),
            "Incorrect email or password."
        );
        assert_eq!(
            account_error_message(&AccountError::InvalidToken),
            "This link is invalid or has expired."
        );
        assert_eq!(
            account_error_message(&AccountError::DuplicateEmail("x".into())),
            "An account with that email already exists."
        );
    }

    #[test]
    fn landing_lists_install_instructions() {
        let html = component::<Landing>(LandingProps {
            logged_in: false,
            email: None,
        })
        .to_html();
        assert!(html.contains("Install"), "landing has an install section");
        assert!(html.contains("github:ElementalPlaneOfAir/cococoir"), "flake input documented");
        assert!(html.contains("fortress.services.jellyfin"), "service enable documented");
        assert!(html.contains("nixos-rebuild switch"), "rebuild command documented");
        assert!(html.contains("living-room"), "multi-machine example documented");
        assert!(html.contains("nixosConfigurations"), "flake structure documented");
    }
}