//! The human-facing HTML surfaces, rendered by topcoat. Everything the
//! site serves except `/api/*` lives here — that boundary is the whole
//! separation of concerns (axum owns the machine contract, topcoat owns
//! the pages).

pub mod auth;
pub mod docs;
pub mod home;
pub mod install;
pub mod shell;
