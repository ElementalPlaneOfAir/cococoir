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

// Use it anywhere!
let button = rsx!(
    <Button text="Click me" variant="primary">
        <span>"→"</span>
    </Button>
);

