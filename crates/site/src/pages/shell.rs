//! The root layout every topcoat page nests under: the zine document
//! shell with the design tokens inlined. Zero third-party origins at
//! runtime — asserted by `pages_have_no_external_asset_origins`.

use topcoat::{
    Result as TcResult,
    router::{Slot, layout},
    view::{View, view},
};

#[layout("/")]
pub async fn root_layout(slot: Slot<'_>) -> TcResult<impl View> {
    Ok(view! {
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <title>"Fortress — your home server, your rules"</title>
                <style>(fortress_web_ui::ZINE_CSS)</style>
                <style>(fortress_web_ui::LOUD_CSS)</style>
            </head>
            <body class="zine-body">
                (slot)
            </body>
        </html>
    })
}
