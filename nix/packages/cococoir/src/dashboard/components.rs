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

#[derive(Default)]
pub struct IndexProps {
    pub count: usize,
}
// #[component]
pub fn IndexPage(props: &IndexProps) -> Node {
    let countstr = format!("{}", props.count);
    rsx!(
    <html lang="en">
    <head>
    <title/>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <link href="css/style.css" rel="stylesheet"/>
    </head>
    <body>
    "This page has been loaded: " {countstr} " times."
    </body>
    </html>
    )
}
