extern crate alloc;
use momenta::prelude::*;

pub struct HtmxTestProps {
    pub count: usize,
}

#[component]
pub fn HtmxTest(props: &HtmxTestProps) -> Node {
    let countstr = format!("{}", props.count);
    rsx!(
    <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
            <h2 class="card-title">"Page loads"</h2>
            <p>"This page has been loaded " {countstr} " times."</p>
            <div class="card-actions">
                <button class="btn btn-primary btn-sm" data_hx_target="closest .card" data_hx_post="/update">
                    "Increment"
                </button>
            </div>
        </div>
    </div>
    )
}

pub struct LoginPageProps {
    pub error: bool,
}

#[component]
pub fn LoginPage(props: &LoginPageProps) -> Node {
    rsx!(
    <html lang="en" data_theme="dark">
    <head>
    <title>"Sign in"</title>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
    <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
    </head>
    <body class="min-h-screen flex items-center justify-center bg-base-200 p-4">
    <div class="card w-full max-w-sm bg-base-100 shadow-xl">
        <div class="card-body">
            <h1 class="card-title text-2xl">"Cococoir"</h1>
            <p class="text-sm text-base-content/60">"Sign in to the admin dashboard"</p>
            <form method="post" action="/auth/login" class="flex flex-col gap-4">
                <label class="input input-bordered flex items-center gap-2">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke_width="2" stroke_linecap="round" stroke_linejoin="round" class="h-4 w-4 opacity-70">
                    <path d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z"/>
                    </svg>
                    <input id="password" type="password" name="password" required placeholder="Password" class="grow"/>
                </label>
                <button type="submit" class="btn btn-primary">"Sign in"</button>
            </form>
            {if props.error { rsx!(<div role="alert" class="alert alert-error"><span>"Incorrect password."</span></div>) } else { Node::Empty }}
        </div>
    </div>
    </body>
    </html>
    )
}

pub struct IndexProps {
    pub name: String,
    pub count: usize,
}

/// One service row in the config editor.
pub struct EditorServiceProps {
    pub nixname: String,
    pub display_name: &'static str,
    pub description: &'static str,
    pub enabled: bool,
    /// Whether the `enable` binding exists in the file. Undeclared
    /// services are read-only (the parser cannot insert bindings yet).
    pub declared: bool,
}

/// One user row in the config editor.
pub struct EditorUserProps {
    pub username: String,
    pub is_admin: bool,
    pub groups: Vec<String>,
    pub has_password: bool,
    /// Whether a `groups` binding exists in the file; when false the
    /// groups input renders read-only.
    pub groups_declared: bool,
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
    if enabled { Some(true) } else { None }
}

#[component]
pub fn EditorPage(props: &EditorPageProps) -> Node {
    let services_html = props
        .services
        .iter()
        .map(|service| {
            let checked = checked_attr(service.enabled);
            let disabled = checked_attr(!service.declared);
            let hint = if service.declared {
                String::new()
            } else {
                " not declared in file — add manually".to_string()
            };
            rsx!(
                <label class="flex items-center justify-between gap-4 rounded-xl bg-base-200/50 px-4 py-3">
                    <span class="flex flex-col">
                        <span class="font-medium">{service.display_name}</span>
                        <span class="text-sm text-base-content/60">{service.description}{hint}</span>
                    </span>
                    <input type="checkbox" name={"svc_".to_string() + &service.nixname} value="true" checked={checked} disabled={disabled} class="toggle toggle-primary"/>
                </label>
            )
        })
        .collect::<Vec<_>>();

    let users_html = props
        .users
        .iter()
        .map(|user| {
            let admin_badge = if user.is_admin {
                rsx!(<span class="badge badge-error badge-xs">"admin"</span>)
            } else {
                Node::Empty
            };
            let password_badge = if user.has_password {
                rsx!(<span class="badge badge-neutral badge-xs">"password set"</span>)
            } else {
                Node::Empty
 };
            let groups = user.groups.join(", ");
            let disabled = checked_attr(!user.groups_declared);
            let hint = if user.groups_declared {
                String::new()
            } else {
                " groups not declared in file — add manually".to_string()
            };
            rsx!(
                <div class="flex items-center justify-between gap-4 rounded-xl bg-base-200/50 px-4 py-3">
                    <span class="flex items-center gap-2">
                        <span class="font-medium">{&user.username}</span>
                        {admin_badge}
                        {password_badge}
                    </span>
                    <span class="flex flex-col items-end gap-1">
                        <input type="text" name={"groups_".to_string() + &user.username} value={groups} disabled={disabled} class="input input-sm input-bordered w-64"/>
                        <span class="text-xs text-base-content/50">{hint}</span>
                    </span>
                </div>
            )
        })
        .collect::<Vec<_>>();

    let error_banner = match &props.config_error {
        Some(message) => rsx!(
            <div role="alert" class="alert alert-error">
                <span>"Could not load the config file: " {message}</span>
            </div>
        ),
        None => Node::Empty,
    };
    let saved_banner = if props.saved {
        rsx!(
            <div role="alert" class="alert alert-success">
                <span>"Saved."</span>
            </div>
        )
    } else {
        Node::Empty
    };
    let save_error_banner = match &props.save_error {
        Some(message) => rsx!(
            <div role="alert" class="alert alert-error">
                <span>"Not saved: " {message}</span>
            </div>
        ),
        None => Node::Empty,
    };

    rsx!(
    <html lang="en" data_theme="dark">
    <head>
    <title>"Cococoir"</title>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/htmx/2.0.10/htmx.min.js"/>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
    <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
    </head>
    <body class="min-h-screen bg-base-200">
    <div class="navbar bg-base-100 shadow-sm">
        <div class="flex-1 px-2">
            <span class="text-lg font-semibold">"Cococoir"</span>
        </div>
        <div class="flex-none px-2">
            <a href="/auth/logout" class="btn btn-ghost btn-sm">"Sign out"</a>
        </div>
    </div>
    <main class="mx-auto flex max-w-2xl flex-col gap-4 p-6">
        {error_banner}
        {saved_banner}
        {save_error_banner}
        <form method="post" action="/" class="flex flex-col gap-6">
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-4">
                    <h2 class="card-title">"System"</h2>
                    <label class="form-control w-full">
                        <div class="label"><span class="label-text">"Hostname"</span></div>
                        <input type="text" name="hostname" value={&props.hostname} class="input input-bordered"/>
                    </label>
                    <label class="form-control w-full">
                        <div class="label"><span class="label-text">"Base domain"</span></div>
                        <input type="text" name="base_domain" value={&props.base_domain} class="input input-bordered"/>
                    </label>
                </div>
            </div>
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-3">
                    <h2 class="card-title">"Services"</h2>
                    {services_html}
                </div>
            </div>
            <div class="card bg-base-100 shadow-sm">
                <div class="card-body flex flex-col gap-3">
                    <h2 class="card-title">"Users"</h2>
                    {users_html}
                </div>
            </div>
            <button type="submit" class="btn btn-primary">"Save"</button>
        </form>
    </main>
    </body>
    </html>
    )
}

#[component]
pub fn IndexPage(props: &IndexProps) -> Node {
    rsx!(
    <html lang="en" data_theme="dark">
    <head>
    <title>"Cococoir"</title>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/htmx/2.0.10/htmx.min.js"/>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
    <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
    </head>
    <body class="min-h-screen bg-base-200">
    <div class="navbar bg-base-100 shadow-sm">
        <div class="flex-1 px-2">
            <span class="text-lg font-semibold">"Cococoir"</span>
        </div>
        <div class="flex-none px-2">
            <a href="/auth/logout" class="btn btn-ghost btn-sm">"Sign out"</a>
        </div>
    </div>
    <main class="mx-auto flex max-w-5xl flex-col gap-6 p-6">
        <div class="hero rounded-2xl bg-base-100 shadow-sm">
            <div class="hero-content py-10 text-center">
                <div class="max-w-md">
                    <h1 class="text-4xl font-bold">"Hello " {&props.name}</h1>
                    <p class="py-4 text-base-content/60">"Cococoir admin dashboard"</p>
                </div>
            </div>
        </div>
        <HtmxTest count={props.count}/>
    </main>
    </body>
    </html>
    )
}
