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

