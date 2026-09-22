//! The composition seam: axum owns `/api/*` (the machine contract),
//! topcoat owns every human HTML surface.
//!
//! Deliberately merged at the root with full `/api/...` paths rather than
//! `nest`ed under `/api` — axum's `nest` strips the prefix and would 404
//! every route. That is a silent-failure seam and the T1 spike asserts
//! the exact `pairing.rs` wire paths land.

use axum::Router as AxumRouter;

use crate::SiteBackend;
use crate::api;
use crate::app::pages_service;

/// The whole site, one router, one listener.
pub fn app(backend: &'static SiteBackend) -> AxumRouter {
    api::router(backend).fallback_service(pages_service(backend))
}
