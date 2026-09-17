// SPDX-License-Identifier: AGPL-3.0-or-later
//! The shared Fortress web design system: paper-zine tokens, document
//! shells, and momenta components. Every customer-facing surface — the
//! controlplane landing and auth pages, the machines dashboard, and the
//! client's local dashboard — renders through this crate so the look
//! lives in exactly one place.
//!
//! CSS strategy: Tailwind utility classes for layout, compiled at page
//! load by the vendored `@tailwindcss/browser` runtime inlined below.
//! No third-party origins at runtime; the class names are the stable
//! interface if we later swap in a CLI-built stylesheet.

use momenta::prelude::*;

/// The pinned upstream build inlined by the shells. Bumping this means
/// re-vendoring `assets/tailwind-browser.js` from the same version.
pub const TAILWIND_BROWSER_VERSION: &str = "4.3.3";

const TAILWIND_BROWSER_JS: &str = include_str!("../assets/tailwind-browser.js");

/// The pinned vendored htmx build for dashboard interactivity. Bumping
/// this means re-vendoring `assets/htmx.js` from the same version.
pub const HTMX_VERSION: &str = "2.0.10";

const HTMX_JS: &str = include_str!("../assets/htmx.js");

/// How loud the surface is allowed to be.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ShellVariant {
    /// Landing-page agitprop: grain overlay, marquee ticker, torn edges.
    Loud,
    /// Working pages: same tokens, texture stripped, data-first.
    App,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FieldKind {
    Text,
    Email,
    Password,
}

impl FieldKind {
    fn html_type(self) -> &'static str {
        match self {
            FieldKind::Text => "text",
            FieldKind::Email => "email",
            FieldKind::Password => "password",
        }
    }
}

fn assert_non_empty(name: &str, value: &str) {
    assert!(!value.trim().is_empty(), "{name} must be non-empty");
}

/// The design-system stylesheet: paper/ink/red tokens, stamp badges,
/// hard-shadow cards, and the form-field skin. Injected raw via
/// `_dangerously_set_inner_html` because a `<style>` child would have
/// its `>` and `/` escaped as text.
pub const ZINE_CSS: &str = r#"
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
  .zine-input {
    display: block;
    width: 100%;
    background: var(--paper);
    border: 2px solid var(--ink);
    color: var(--ink);
    padding: 0.6rem 0.8rem;
    font-family: inherit;
    font-size: 0.9rem;
  }
  .zine-input:focus { outline: 3px solid var(--red); outline-offset: 0; }
  .zine-toggle { accent-color: var(--red); width: 1.25rem; height: 1.25rem; flex: none; }
  .alert-zine {
    border: 2px solid var(--red);
    color: var(--red);
    background: var(--paper);
    padding: 0.6rem 0.9rem;
    font-size: 0.85rem;
    font-weight: 700;
  }
  .alert-zine-ok {
    border: 2px solid var(--ink);
    color: var(--ink);
    background: var(--paper);
    padding: 0.6rem 0.9rem;
    font-size: 0.85rem;
    font-weight: 700;
  }
"#;

/// The ornament layer: grain overlay, halftone, torn dividers and the
/// marquee. Only the `Loud` shell variant ships this.
pub const LOUD_CSS: &str = r#"
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

/// A full HTML document with the vendored Tailwind runtime and the zine
/// stylesheet inlined, on the paper base. The `Loud` variant additionally
/// ships the ornament layer (grain, halftone, tears, marquee); `App`
/// pages get the same tokens with the texture stripped. `extra_head`
/// carries optional page-specific head content (e.g. the htmx runtime).
pub fn shell(title: &str, variant: ShellVariant, body: Node) -> Node {
    shell_with_head(title, variant, Node::Empty, body)
}

pub fn shell_with_head(title: &str, variant: ShellVariant, extra_head: Node, body: Node) -> Node {
    assert_non_empty("title", title);
    let body_class = match variant {
        ShellVariant::Loud => "zine",
        ShellVariant::App => "zine app",
    };
    let ornament_style = match variant {
        ShellVariant::Loud => rsx!(<style _dangerously_set_inner_html={LOUD_CSS}></style>),
        ShellVariant::App => Node::Empty,
    };
    rsx!(
        <html lang="en">
            <head>
                <title>{title}</title>
                <meta charset="UTF-8"/>
                <meta name="viewport" content="width=device-width, initial-scale=1"/>
                <script _dangerously_set_inner_html={TAILWIND_BROWSER_JS}></script>
                <style _dangerously_set_inner_html={ZINE_CSS}></style>
                {ornament_style}
                {extra_head}
            </head>
            <body class={body_class}>{body}</body>
        </html>
    )
}

/// The inlined htmx runtime for dashboard pages that opt into it.
pub fn htmx_script() -> Node {
    rsx!(<script _dangerously_set_inner_html={HTMX_JS}></script>)
}

/// A rotated rubber-stamp badge.
pub fn stamp(text: &str) -> Node {
    assert_non_empty("stamp text", text);
    rsx!(<span class="stamp">{text}</span>)
}

/// A smaller rubber stamp, for inline use ("soon") and status badges.
pub fn stamp_small(text: &str) -> Node {
    assert_non_empty("stamp text", text);
    rsx!(<span class="stamp stamp-sm">{text}</span>)
}

/// A hard-shadow push button rendered as a link.
pub fn zine_button(href: &str, label: &str, extra_class: &str) -> Node {
    assert_non_empty("button href", href);
    assert_non_empty("button label", label);
    let class = format!("btn-zine {extra_class}");
    rsx!(<a href={href} class={class}>{label}</a>)
}

/// The primary form submit button.
pub fn zine_submit(label: &str, extra_class: &str) -> Node {
    assert_non_empty("submit label", label);
    let class = format!("btn-zine btn-zine-red {extra_class}");
    rsx!(<button type="submit" class={class}>{label}</button>)
}

/// A paper card with the hard offset shadow; owns the body layout
/// (padding, column, gap). `extra_class` adds caller tweaks (h-full,
/// text-center, ...).
pub fn card(extra_class: &str, body: Node) -> Node {
    let class = format!("zine-card p-6 flex flex-col gap-3 {extra_class}");
    rsx!(<div class={class}>{body}</div>)
}

/// A centered, uppercase section heading with the red mark treatment.
pub fn section_heading(text: &str) -> Node {
    assert_non_empty("heading text", text);
    rsx!(<h2 class="text-center text-3xl font-black uppercase mb-10"><span class="mark">{text}</span></h2>)
}

/// An ink code block with the red spine. The content is trusted author
/// text (source snippets from this repo), injected unescaped so the
/// served HTML keeps it copy-pasteable — never pass user input here.
pub fn code_block(code: &str) -> Node {
    assert_non_empty("code", code);
    assert!(
        !code.contains("</"),
        "code block content must not contain markup"
    );
    rsx!(<pre class="code-zine" _dangerously_set_inner_html={code}></pre>)
}

/// A list whose items carry the red chevron.
pub fn tick_list(items: &[&str]) -> Node {
    assert!(!items.is_empty(), "tick list needs items");
    rsx!(
        <ul class="flex flex-col gap-2 text-sm">
            {items.iter().map(|item| rsx!(<li class="tick">{*item}</li>))}
        </ul>
    )
}

/// The red torn-paper divider.
pub fn torn() -> Node {
    rsx!(<div class="torn"></div>)
}

/// A red agitprop marquee strip. `phrase` is repeated to fill both
/// halves of the scroll track.
pub fn ticker(phrase: &str) -> Node {
    assert_non_empty("ticker phrase", phrase);
    let track = phrase.repeat(4);
    rsx!(
        <div class="ticker" aria_hidden={true}>
            <div class="ticker-track">
                <span>{track.clone()}</span>
                <span>{track}</span>
            </div>
        </div>
    )
}

/// A labeled form field on the paper skin.
pub fn field(
    label: &str,
    name: &str,
    kind: FieldKind,
    value: Option<&str>,
    hint: Option<&str>,
) -> Node {
    assert_non_empty("field label", label);
    assert_non_empty("field name", name);
    let input_type = kind.html_type();
    let input_value = value.unwrap_or("");
    let hint_node = match hint {
        Some(text) => rsx!(<div class="mt-1 text-xs faint">{text}</div>),
        None => Node::Empty,
    };
    rsx!(
        <label class="block">
            <div class="tag dim mb-1">{label}</div>
            <input type={input_type} name={name} value={input_value} required class="zine-input"/>
            {hint_node}
        </label>
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(body: Node) -> String {
        body.to_html()
    }

    #[test]
    fn app_shell_strips_loud_texture() {
        let loud = render(shell("loud page", ShellVariant::Loud, rsx!(<main>"x"</main>)));
        let app = render(shell("app page", ShellVariant::App, rsx!(<main>"x"</main>)));
        assert!(loud.contains(r#"class="zine""#));
        assert!(app.contains(r#"class="zine app""#));
        for loud_only in ["ticker", "torn", "halftone"] {
            assert!(
                !app.contains(loud_only),
                "app shell must not ship the {loud_only} texture"
            );
        }
    }

    #[test]
    fn shell_inlines_every_asset() {
        let page = render(shell("t", ShellVariant::Loud, Node::Empty));
        assert!(page.contains(TAILWIND_BROWSER_VERSION));
        assert!(page.contains("--red: #d02a1e"));
        assert!(!page.contains("cdn.jsdelivr"), "no third-party origins");
    }

    #[test]
    fn htmx_pages_inline_the_runtime() {
        let page = render(shell_with_head(
            "t",
            ShellVariant::App,
            htmx_script(),
            Node::Empty,
        ));
        assert!(page.contains(HTMX_VERSION));
        assert!(!page.contains("cdnjs.cloudflare.com"), "no CDN htmx");
    }

    #[test]
    fn components_refuse_empty_input() {
        let cases: Vec<Box<dyn Fn() -> Node>> = vec![
            Box::new(|| stamp(" ")),
            Box::new(|| stamp_small("")),
            Box::new(|| zine_button("", "label", "")),
            Box::new(|| zine_button("/x", " ", "")),
            Box::new(|| section_heading("")),
            Box::new(|| code_block("")),
            Box::new(|| ticker(" ")),
            Box::new(|| field("", "n", FieldKind::Text, None, None)),
            Box::new(|| field("l", "", FieldKind::Email, None, None)),
        ];
        for build in cases {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(build));
            assert!(result.is_err(), "empty component input must assert");
        }
    }

    #[test]
    fn cards_render_children_with_body_layout() {
        let page = render(card("h-full", rsx!(<h3>"Buy a box"</h3>)));
        assert!(page.contains("zine-card p-6 flex flex-col gap-3 h-full"));
        assert!(page.contains("<h3>Buy a box</h3>"));
    }

    #[test]
    fn fields_render_skin_and_kind() {
        let text = render(field("Email", "email", FieldKind::Email, None, Some("hint")));
        assert!(text.contains(r#"type="email""#));
        assert!(text.contains("zine-input"));
        assert!(text.contains("hint"));
        let password = render(field("Password", "password", FieldKind::Password, Some("x"), None));
        assert!(password.contains(r#"type="password""#));
        assert!(password.contains(r#"value="x""#));
    }
}

