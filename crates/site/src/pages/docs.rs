//! The markdown wiki at `/docs` and `/docs/{slug}`. Folder-as-content,
//! path-based routing, no per-page Rust. Document-origin-only rendering
//! law: the markdown is compiled in this process and inlined, never
//! fetched.

use topcoat::{
    Result as TcResult,
    context::Cx,
    router::{error::not_found, page, path_param},
    view::{Unescaped, View, view},
};

use crate::{DOC_CSS, doc_html};

path_param!(slug);

#[page("/docs")]
pub async fn docs_index(cx: &Cx) -> TcResult<impl View> {
    let _ = cx;
    let items: String = crate::DOC_PAGES
        .iter()
        .map(|(slug, title, ..)| format!("<li><a href=\"/docs/{slug}\">{title}</a></li>"))
        .collect();
    let html = format!("<main class=\"doc\"><h1>Documentation</h1><ul>{items}</ul><style>{DOC_CSS}</style></main>");
    Ok(view! { (Unescaped::new_unchecked(html)) })
}

#[page("/docs/{slug}")]
pub async fn docs_page(cx: &Cx) -> TcResult<impl View> {
    let slug = path_param::<Slug>(cx);
    let body = doc_html(slug).map_err(|_| not_found())?;
    let html = format!("<main class=\"doc\">{body}<style>{DOC_CSS}</style></main>");
    Ok(view! { (Unescaped::new_unchecked(html)) })
}
