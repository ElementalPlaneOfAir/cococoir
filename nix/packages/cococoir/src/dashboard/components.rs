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
