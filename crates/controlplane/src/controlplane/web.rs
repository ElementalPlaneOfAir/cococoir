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

/// The landing page's zine stylesheet: paper/ink/red palette, grain and
/// halftone texture, stamp badges, hard-shadow cards, and the jagged
/// section tears. Injected raw via `_dangerously_set_inner_html` because
/// a `<style>` child would have its `>` and `/` escaped as text.
const LANDING_CSS: &str = r#"
  :root {
    --paper: #f3eee3;
    --ink: #16110b;
    --red: #d02a1e;
    --red-deep: #8f1410;
  }
  body {
    background: var(--paper);
    color: var(--ink);
    font-family: ui-monospace, "Cascadia Mono", Menlo, Consolas, "Liberation Mono", monospace;
  }
  body::after {
    content: "";
    position: fixed;
    inset: 0;
    z-index: 50;
    pointer-events: none;
    mix-blend-mode: multiply;
    opacity: 0.5;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='2'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)' opacity='0.22'/%3E%3C/svg%3E");
  }
  ::selection { background: var(--red); color: var(--paper); }
  .bg-paper { background: var(--paper); }
  .text-ink { color: var(--ink); }
  .text-red { color: var(--red); font-weight: 700; }
  .bg-red { background: var(--red); }
  .border-ink { border-color: var(--ink); }
  .dim { color: rgba(22, 17, 11, 0.72); }
  .faint { color: rgba(22, 17, 11, 0.5); }
  .tag { font-size: 0.78rem; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; }
  .mark {
    background: var(--red);
    color: var(--paper);
    padding: 0 0.18em;
    -webkit-box-decoration-break: clone;
    box-decoration-break: clone;
  }
  .stamp {
    display: inline-block;
    border: 2.5px solid var(--red);
    color: var(--red);
    padding: 0.55rem 1rem;
    font-weight: 700;
    font-size: 0.72rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    transform: rotate(-2deg);
  }
  .stamp-sm { padding: 0.3rem 0.7rem; border-width: 2px; font-size: 0.65rem; }
  .btn-zine {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 2px solid var(--ink);
    background: var(--paper);
    color: var(--ink);
    padding: 0.8rem 1.6rem;
    font-weight: 700;
    font-size: 0.9rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    text-decoration: none;
    box-shadow: 6px 6px 0 var(--ink);
    transition: transform 80ms, box-shadow 80ms;
  }
  .btn-zine:hover { transform: translate(3px, 3px); box-shadow: 3px 3px 0 var(--ink); }
  .btn-zine-red { background: var(--red); color: var(--paper); }
  .btn-zine-sm { padding: 0.45rem 0.8rem; font-size: 0.72rem; box-shadow: 4px 4px 0 var(--ink); }
  .btn-zine-sm:hover { transform: translate(2px, 2px); box-shadow: 2px 2px 0 var(--ink); }
  .zine-card {
    background: var(--paper);
    border: 2px solid var(--ink);
    box-shadow: 8px 8px 0 var(--ink);
  }
  .code-zine {
    background: var(--ink);
    color: var(--paper);
    border-left: 6px solid var(--red);
    padding: 1rem;
    font-size: 0.8rem;
    line-height: 1.55;
    overflow-x: auto;
    white-space: pre;
  }
  .stepnum {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 1.8rem;
    height: 1.8rem;
    flex: none;
    background: var(--red);
    color: var(--paper);
    font-weight: 700;
    border: 2px solid var(--ink);
    box-shadow: 2px 2px 0 var(--ink);
  }
  .tick::before {
    content: "»";
    color: var(--red);
    font-weight: 700;
    margin-right: 0.5rem;
  }
  .crossed {
    text-decoration: line-through;
    text-decoration-color: var(--red);
    text-decoration-thickness: 3px;
  }
  .chip {
    border: 2px solid var(--ink);
    background: var(--paper);
    box-shadow: 3px 3px 0 var(--ink);
    padding: 0.4rem 0.8rem;
    font-size: 0.82rem;
  }
  .link-zine {
    color: var(--ink);
    font-weight: 700;
    text-transform: uppercase;
    font-size: 0.78rem;
    letter-spacing: 0.08em;
    text-decoration: underline;
    text-decoration-color: var(--red);
    text-decoration-thickness: 3px;
    text-underline-offset: 3px;
  }
  .halftone {
    background-image: radial-gradient(circle, rgba(22, 17, 11, 0.13) 1.1px, transparent 1.2px);
    background-size: 9px 9px;
  }
  .torn {
    height: 16px;
    background: var(--red);
    clip-path: polygon(0 45%, 2% 75%, 4% 30%, 7% 80%, 10% 35%, 13% 75%, 16% 25%, 19% 70%, 22% 40%, 25% 85%, 28% 30%, 31% 70%, 34% 35%, 37% 80%, 40% 25%, 43% 75%, 46% 40%, 49% 85%, 52% 30%, 55% 70%, 58% 35%, 61% 80%, 64% 25%, 67% 70%, 70% 40%, 73% 85%, 76% 30%, 79% 75%, 82% 35%, 85% 80%, 88% 25%, 91% 70%, 94% 40%, 97% 80%, 100% 35%, 100% 100%, 0 100%);
  }
  .ticker { background: var(--red); color: var(--paper); overflow: hidden; border-bottom: 2px solid var(--ink); }
  .ticker-track { display: flex; width: max-content; animation: ticker-scroll 36s linear infinite; }
  .ticker-track span { display: inline-block; padding: 0.35rem 0; font-size: 0.72rem; font-weight: 700; letter-spacing: 0.16em; text-transform: uppercase; }
  @keyframes ticker-scroll { to { transform: translateX(-50%); } }
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
        <html lang="en" data_theme="light">
            <head>
                <title>"Fortress — your home server, your rules"</title>
                <meta charset="UTF-8"/>
                <meta name="viewport" content="width=device-width, initial-scale=1"/>
                <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
                <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css"/>
                <style _dangerously_set_inner_html={LANDING_CSS}></style>
            </head>
            <body class="min-h-screen text-ink">{main}</body>
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
                <span class="tag dim hidden sm:inline">{props.email.as_deref().unwrap_or("")}</span>
                <a href="/auth/logout" class="btn-zine btn-zine-sm">"Sign out"</a>
            </>
        )
    } else {
        rsx!(<a href="/register" class="btn-zine btn-zine-red btn-zine-sm">"Create account"</a>)
    };

    // The hero's primary CTA: always the account/order path.
    let hero_cta = if props.logged_in {
        rsx!(<a href="/" class="btn-zine btn-zine-red">"Go to my dashboard"</a>)
    } else {
        rsx!(<a href="/register" class="btn-zine btn-zine-red">"Order a box"</a>)
    };

    let ticker_text =
        "no masters · no clouds · your keys, your machine · worker cooperative · open source · agpl-3.0 · no ads · no tracking · ".repeat(4);

    landing_shell(rsx!(
        <>

            <nav class="sticky top-0 z-40 bg-paper border-b-2 border-ink px-6">
                <div class="flex-1 flex items-center gap-2">
                    {shield_icon("h-6 w-6 text-red")}
                    <span class="text-lg font-black uppercase tracking-tight">"Fortress"</span>
                </div>
                <div class="flex-none flex items-center gap-4">
                    <a href="#install" class="tag dim hidden sm:inline">"Install"</a>
                    {nav_auth}
                </div>
            </nav>

            <div class="ticker" aria_hidden={true}>
                <div class="ticker-track">
                    <span>{ticker_text.clone()}</span>
                    <span>{ticker_text.clone()}</span>
                </div>
            </div>

            <header class="halftone px-6 pt-16 pb-14 text-center">
                <div class="mx-auto max-w-3xl">
                    <div class="stamp mb-8">"A worker cooperative · open source · NixOS"</div>
                    <h1 class="text-5xl sm:text-6xl font-black uppercase leading-[1.02] tracking-tight">
                        <span class="block">"Your home server."</span>
                        <span class="block mt-3"><span class="mark">"Your data. Your rules."</span></span>
                    </h1>
                    <p class="mx-auto mt-8 max-w-xl text-lg dim">
                        "Fortress replaces Google Docs, Dropbox, Netflix and Ring with a self-hosted box in your house — reachable from anywhere, with every key on your own hardware."
                    </p>
                    <div class="mt-10 flex flex-col sm:flex-row items-center justify-center gap-4">
                        {hero_cta}
                        <a href="#install" class="btn-zine">"Install it yourself"</a>
                    </div>
                    <div class="mt-12 flex flex-wrap items-center justify-center gap-x-6 gap-y-3">
                        <span class="tag dim">"Own your data"</span>
                        <span class="text-red">"★"</span>
                        <span class="tag dim">"Remote access built in"</span>
                        <span class="text-red">"★"</span>
                        <span class="tag dim">"One login for everything"</span>
                        <span class="text-red">"★"</span>
                        <span class="tag dim">"No subscription lock-in"</span>
                    </div>
                </div>
            </header>

            <div class="torn"></div>

            <section class="px-6 py-12">
                <div class="mx-auto max-w-5xl">
                    <div class="flex flex-wrap items-center justify-center gap-4">
                        <span class="tag dim mr-2">"Replaces:"</span>
                        <div class="flex flex-wrap justify-center gap-4">
                            <span class="chip"><span class="crossed">"Google Docs"</span>" → "<b class="text-red">"CryptPad"</b></span>
                            <span class="chip"><span class="crossed">"Netflix"</span>" → "<b class="text-red">"Jellyfin"</b></span>
                            <span class="chip">"+ Radarr, Sonarr, Lidarr, Prowlarr"</span>
                            <span class="chip">"Nextcloud"<span class="stamp stamp-sm ml-2">"soon"</span></span>
                        </div>
                    </div>
                </div>
            </section>

            <section class="px-6 py-14">
                <div class="mx-auto max-w-5xl">
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-8">
                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-start justify-between gap-2">
                                <h3 class="font-black uppercase text-lg leading-tight">"Your keys, your hardware"</h3>
                                <span class="text-red text-xl font-black">"01"</span>
                            </div>
                            <p class="text-sm dim">"TLS and WireGuard keys never leave your house. Nobody else can decrypt your traffic — not even us."</p>
                        </div>
                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-start justify-between gap-2">
                                <h3 class="font-black uppercase text-lg leading-tight">"Reachable anywhere"</h3>
                                <span class="text-red text-xl font-black">"02"</span>
                            </div>
                            <p class="text-sm dim">"One encrypted tunnel to a box in the cloud. Jellyfin, docs, photos — from any phone, on any network, no port forwarding."</p>
                        </div>
                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-start justify-between gap-2">
                                <h3 class="font-black uppercase text-lg leading-tight">"One login for everything"</h3>
                                <span class="text-red text-xl font-black">"03"</span>
                            </div>
                            <p class="text-sm dim">"Every service signs in with the same account. Add a user once, they get every app — no per-app password sprawl."</p>
                        </div>
                    </div>
                </div>
            </section>

            <section class="px-6 py-14">
                <div class="mx-auto max-w-5xl">
                    <h2 class="text-center text-3xl font-black uppercase mb-10"><span class="mark">"Two ways in"</span></h2>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
                        <div class="zine-card p-6 flex flex-col gap-3 h-full">
                            <div class="stamp stamp-sm w-fit">"Zero setup"</div>
                            <h3 class="text-2xl font-black uppercase">"Buy a box"</h3>
                            <p class="text-sm dim">"We assemble, install and ship a pre-configured Fortress. Plug it in, connect ethernet, and claim it with your account in under five minutes."</p>
                            <ul class="flex flex-col gap-2 text-sm">
                                <li class="tick">"Pre-installed NixOS + all services"</li>
                                <li class="tick">"Encrypted offsite backups included"</li>
                                <li class="tick">"Support from real humans"</li>
                            </ul>
                            <div class="mt-auto pt-3"><a href="/register" class="btn-zine btn-zine-red">"Get yours"</a></div>
                        </div>
                        <div class="zine-card p-6 flex flex-col gap-3 h-full">
                            <div class="stamp stamp-sm w-fit">"Bring your own hardware"</div>
                            <h3 class="text-2xl font-black uppercase">"Install on your machine"</h3>
                            <p class="text-sm dim">"Fortress is a NixOS module. Point your flake at it, enable the services you want, rebuild. No setup wizard, no app store."</p>
                            <ul class="flex flex-col gap-2 text-sm">
                                <li class="tick">"Free forever, AGPL-3.0"</li>
                                <li class="tick">"Run as many machines as you like"</li>
                                <li class="tick">"Same remote access as a box"</li>
                            </ul>
                            <div class="mt-auto pt-3"><a href="#install" class="btn-zine">"See the install guide"</a></div>
                        </div>
                    </div>
                </div>
            </section>

            <section id="install" class="px-6 py-14 scroll-mt-16">
                <div class="mx-auto max-w-3xl">
                    <h2 class="text-center text-3xl font-black uppercase mb-2">"Install on your own machines"</h2>
                    <p class="text-center dim mb-10">"Runs on any x86-64 NixOS machine. Each machine is one file in your flake."</p>

                    <div class="flex flex-col gap-8">
                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-center gap-3">
                                <span class="stepnum">"1"</span>
                                <h3 class="font-black uppercase">"Add the flake input"</h3>
                            </div>
                            <pre class="code-zine">{r#"{
  inputs = {
    fortress.url = "github:ElementalPlaneOfAir/cococoir";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}"#}</pre>
                        </div>

                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-center gap-3">
                                <span class="stepnum">"2"</span>
                                <h3 class="font-black uppercase">"Import the module"</h3>
                            </div>
                            <pre class="code-zine">{r#"{
  imports = [ inputs.fortress.nixosModules.default ];
}"#}</pre>
                        </div>

                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-center gap-3">
                                <span class="stepnum">"3"</span>
                                <h3 class="font-black uppercase">"Enable services and rebuild"</h3>
                            </div>
                            <pre class="code-zine">{r#"fortress.services.jellyfin = { enable = true; public = true; };
fortress.services.dex      = { enable = true; public = true; };

sudo nixos-rebuild switch --flake .#mybox"#}</pre>
                            <p class="text-sm dim">"Each service gets its own Caddy vhost with automatic TLS. Enable a service next to Dex and every user signs in with one account."</p>
                        </div>

                        <div class="zine-card p-6 flex flex-col gap-3">
                            <div class="flex items-center gap-3">
                                <span class="stepnum">"4"</span>
                                <h3 class="font-black uppercase">"Repeat per machine"</h3>
                            </div>
                            <p class="text-sm dim">"One flake, many machines. Each machine is its own " <code class="text-red">"nixosConfiguration"</code> " importing the same module — give it a hostname, a " <code class="text-red">"fortress.baseDomain"</code> ", and enable the services it should run. Storage, TLS and DNS follow automatically."</p>
                            <pre class="code-zine">{r#"# flake.nix — one module, N machines
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
                            <p class="text-sm dim">"Each machine gets its own Caddy vhosts under your domain. Claim them all under one account for a single set of remote-access routes."</p>
                        </div>
                    </div>
                </div>
            </section>

            <div class="torn"></div>

            <footer class="px-6 py-10 mt-2">
                <div class="mx-auto max-w-5xl flex flex-col sm:flex-row items-center justify-between gap-4">
                    <div class="flex items-center gap-2">
                        {shield_icon("h-5 w-5 text-red")}
                        <span class="tag dim">"Fortress — a worker cooperative. AGPL-3.0."</span>
                    </div>
                    <div class="flex items-center gap-5">
                        <a href="/register" class="link-zine">"Create account"</a>
                        <a href="/login" class="link-zine">"Sign in"</a>
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