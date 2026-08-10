extern crate alloc;
use momenta::prelude::*;

// Define your props - just like React's PropTypes
#[derive(Default)]
struct ButtonProps {
    text: String,
    variant: String,
    children: Vec<Node>,
}

// Create a component - clean and simple
#[component]
fn Button(props: &ButtonProps) -> Node {
    rsx!(
        <button class={format!("btn btn-{}", props.variant)}>
            {&props.text}
            {&props.children}
        </button>
    )
}

pub struct HtmxTestProps {
    pub count: usize,
}
#[component]
pub fn HtmxTest(props: &HtmxTestProps) -> Node {
    let countstr = format!("{}", props.count);
    rsx!(
    <>
        <div>
        <p>
        "This page has been loaded: " {countstr} " times."
        </p>
        <button data_hx_target="closest div" data_hx_post="/update">
            "Increment"
        </button>
        </div>
    </>
    )
}

pub struct IndexProps {
    pub name: String,
    pub count: usize,
}

#[component]
pub fn IndexPage(props: &IndexProps) -> Node {
    rsx!(
    <html lang="en">
    <head>
    <title/>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/htmx/2.0.10/htmx.min.js"/>
    <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"/>
    </head>
    <body>
    <h1>
    "Hello " {&props.name}
    </h1>
    <HtmxTest count={props.count}/>

    </body>
    </html>
    )
}
