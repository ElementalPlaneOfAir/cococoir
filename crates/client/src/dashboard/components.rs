extern crate alloc;
use momenta::prelude::*;

use fortress_web_ui::{
    card, htmx_script, shell, shell_with_head, zine_button, zine_submit, ShellVariant,
};

pub struct LoginPageProps {
    pub error: bool,
}

#[component]
pub fn LoginPage(props: &LoginPageProps) -> Node {
    let banner = if props.error {
        rsx!(<div role="alert" class="alert-zine">"Incorrect password."</div>)
    } else {
        Node::Empty
    };
    shell(
        "Sign in",
        ShellVariant::App,
        rsx!(
            <main class="min-h-screen flex items-center justify-center p-4">
                {card("w-full max-w-sm", rsx!(
                    <>
                        <h1 class="text-2xl font-black uppercase">"Fortress"</h1>
                        <p class="text-sm dim">"Sign in to the admin dashboard"</p>
                        <form method="post" action="/auth/login" class="flex flex-col gap-4">
                            <input id="password" type="password" name="password" required placeholder="Password" class="zine-input"/>
                            {zine_submit("Sign in", "")}
                        </form>
                        {banner}
                    </>
                ))}
            </main>
        ),
    )
}

/// One service card on the landing page. The link is the service's
/// `path` on whatever origin the page was reached from, so the same
/// page works over the LAN address, a public name, and an i2p tunnel
/// with no per-origin logic.
pub struct LandingServiceProps {
    pub name: String,
    pub description: String,
    pub path: String,
    pub healthy: bool,
}

/// The public landing page: every routed service, linked, with the
/// liveness the prober saw. Unauthenticated by design — it is the page
/// a device on the LAN lands on, and it exposes only what the box is
/// already serving on that same network.
pub struct LandingPageProps {
    pub services: Vec<LandingServiceProps>,
}

#[component]
pub fn LandingPage(props: &LandingPageProps) -> Node {
    let cards = props
        .services
        .iter()
        .map(|service| {
            let liveness = if service.healthy {
                fortress_web_ui::stamp_small("up")
            } else {
                fortress_web_ui::stamp_small("down")
            };
            rsx!(
                <a href={service.path.clone()} class="block border-2 border-ink px-4 py-3">
                    <span class="flex items-center justify-between gap-3">
                        <span class="font-black">{&service.name}</span>
                        {liveness}
                    </span>
                    <span class="text-sm dim">{&service.description}</span>
                </a>
            )
        })
        .collect::<Vec<_>>();

    let empty = if props.services.is_empty() {
        rsx!(<p class="text-sm dim">"No services are configured yet. Enable one in the admin panel."</p>)
    } else {
        Node::Empty
    };

    shell(
        "Services",
        ShellVariant::App,
        rsx!(
            <main class="mx-auto flex max-w-3xl flex-col gap-6 p-6">
                <header class="flex items-center justify-between gap-4">
                    <div>
                        <h1 class="text-2xl font-black uppercase">"Services"</h1>
                        <p class="text-sm dim">"Everything this box is running."</p>
                    </div>
                    {zine_button("/admin", "Admin", "")}
                </header>
                <section class="flex flex-col gap-3">
                    {cards}
                    {empty}
                </section>
            </main>
        ),
    )
}

/// One service row in the config editor.
pub struct EditorServiceProps {
    pub nixname: String,
    pub display_name: &'static str,
    pub description: &'static str,
    pub enabled: bool,
}

/// One user row in the config editor.
pub struct EditorUserProps {
    pub username: String,
    pub is_admin: bool,
    pub groups: Vec<String>,
    pub has_password: bool,
}

pub struct EditorPageProps {
    pub hostname: String,
    pub base_domain: String,
    pub services: Vec<EditorServiceProps>,
    pub users: Vec<EditorUserProps>,
    pub config_error: Option<String>,
    pub saved: bool,
    pub save_error: Option<String>,
    pub remote: ClaimView,
}

/// What the Remote access card shows: the claim lifecycle as the box
/// sees it.
pub enum ClaimView {
    /// An enrollment is persisted — remote access is on.
    Claimed { hostname: String },
    /// A claim is dialing the edge / waiting for the owner's approval.
    Awaiting,
    /// The last claim failed; the form comes back with the message.
    Failed { message: String },
    /// Nothing yet — the form is the way in.
    Unclaimed,
}

fn claim_form() -> Node {
    rsx!(
        <form method="post" action="/claim" class="flex flex-col gap-2">
            <label class="block">
                <div class="tag dim mb-1">"Invite link"</div>
                <input type="text" name="invite_url" required placeholder="https://proletariat.tech/i/..." class="zine-input"/>
            </label>
            {zine_submit("Claim this machine", "")}
        </form>
    )
}

fn remote_access_card(view: &ClaimView) -> Node {
    let (stamp, body) = match view {
        ClaimView::Claimed { hostname } => {
            let url = format!("https://{hostname}");
            (
                fortress_web_ui::stamp_small("claimed"),
                rsx!(
                    <>
                        <p class="text-sm dim">"Remote access is on. Sign in at your domain:"</p>
                        <p><code class="font-black">{url}</code></p>
                    </>
                ),
            )
        }
        ClaimView::Awaiting => (
            fortress_web_ui::stamp_small("waiting"),
            rsx!(
                <p class="text-sm dim">"Waiting for the owner's approval on the machines page — then this box restarts into remote access."</p>
            ),
        ),
        ClaimView::Failed { message } => (
            fortress_web_ui::stamp_small("failed"),
            rsx!(
                <>
                    <div role="alert" class="alert-zine">{message.clone()}</div>
                    {claim_form()}
                </>
            ),
        ),
        ClaimView::Unclaimed => (
            fortress_web_ui::stamp_small("not claimed"),
            rsx!(
                <>
                    <p class="text-sm dim">"Generate an invite link on your machines page and paste it here to give this box remote access."</p>
                    {claim_form()}
                </>
            ),
        ),
    };
    rsx!(
        {card("", rsx!(
            <>
                <div class="flex items-center gap-2">
                    <h2 class="font-black uppercase">"Remote access"</h2>
                    {stamp}
                </div>
                {body}
            </>
        ))}
    )
}

fn checked_attr(enabled: bool) -> Option<bool> {
    if enabled {
        Some(true)
    } else {
        None
    }
}

fn app_nav() -> Node {
    rsx!(
        <nav class="sticky top-0 z-40 flex items-center bg-paper border-b-2 border-ink px-6">
            <div class="flex-1 flex items-center gap-2">
                <span class="text-lg font-black uppercase tracking-tight">"Fortress"</span>
            </div>
            <div class="flex-none flex items-center gap-4">
                {zine_button("/auth/logout", "Sign out", "btn-zine-sm")}
            </div>
        </nav>
    )
}

#[component]
pub fn EditorPage(props: &EditorPageProps) -> Node {
    let services_html = props
        .services
        .iter()
        .map(|service| {
            let checked = checked_attr(service.enabled);
            rsx!(
                <label class="flex items-center justify-between gap-4 border-2 border-ink px-4 py-3">
                    <span class="flex flex-col">
                        <span class="font-black">{service.display_name}</span>
                        <span class="text-sm dim">{service.description}</span>
                    </span>
                    <input type="checkbox" name={"svc_".to_string() + &service.nixname} value="true" checked={checked} class="zine-toggle"/>
                </label>
            )
        })
        .collect::<Vec<_>>();

    let users_html = props
        .users
        .iter()
        .map(|user| {
            let admin_badge = if user.is_admin {
                rsx!({fortress_web_ui::stamp_small("admin")})
            } else {
                Node::Empty
            };
            let password_badge = if user.has_password {
                rsx!({fortress_web_ui::stamp_small("password set")})
            } else {
                Node::Empty
            };
            let groups = user.groups.join(", ");
            rsx!(
                <div class="flex items-center justify-between gap-4 border-2 border-ink px-4 py-3">
                    <span class="flex items-center gap-2">
                        <span class="font-black">{&user.username}</span>
                        {admin_badge}
                        {password_badge}
                    </span>
                    <span class="flex flex-col items-end gap-1">
                        <input type="text" name={"groups_".to_string() + &user.username} value={groups} class="zine-input w-64"/>
                    </span>
                </div>
            )
        })
        .collect::<Vec<_>>();

    let error_banner = match &props.config_error {
        Some(message) => rsx!(
            <div role="alert" class="alert-zine">
                "Could not load the config file: " {message}
            </div>
        ),
        None => Node::Empty,
    };
    let saved_banner = if props.saved {
        rsx!(
            <div role="alert" class="alert-zine-ok">
                "Saved."
            </div>
        )
    } else {
        Node::Empty
    };
    let save_error_banner = match &props.save_error {
        Some(message) => rsx!(
            <div role="alert" class="alert-zine">
                "Not saved: " {message}
            </div>
        ),
        None => Node::Empty,
    };

    shell_with_head(
        "Fortress",
        ShellVariant::App,
        htmx_script(),
        rsx!(
            <>
                {app_nav()}
                <main class="mx-auto flex max-w-2xl flex-col gap-4 p-6">
                    {error_banner}
                    {saved_banner}
                    {save_error_banner}
                    {remote_access_card(&props.remote)}
                    <form method="post" action="/" class="flex flex-col gap-6">
                        {card("", rsx!(
                            <>
                                <h2 class="font-black uppercase">"System"</h2>
                                <label class="block">
                                    <div class="tag dim mb-1">"Hostname"</div>
                                    <input type="text" name="hostname" value={&props.hostname} class="zine-input"/>
                                </label>
                                <label class="block">
                                    <div class="tag dim mb-1">"Base domain"</div>
                                    <input type="text" name="base_domain" value={&props.base_domain} class="zine-input"/>
                                </label>
                            </>
                        ))}
                        {card("", rsx!(
                            <>
                                <h2 class="font-black uppercase">"Services"</h2>
                                {services_html}
                            </>
                        ))}
                        {card("", rsx!(
                            <>
                                <h2 class="font-black uppercase">"Users"</h2>
                                {users_html}
                            </>
                        ))}
                        {zine_submit("Save", "")}
                    </form>
                </main>
            </>
        ),
    )
}

