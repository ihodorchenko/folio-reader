//! Folio PDF core (`pdfcore`): PDFium rendering + page structure extraction,
//! element classification and the C ABI for the macOS app.
//!
//! See `pdfreader/CONTRACT.md` — the single source of truth.

pub mod api;
pub mod classify;
pub mod ffi;
mod ffi_api;
pub mod json_types;
pub mod structure;
pub mod text;

pub use api::{Document, RenderOutput};
pub use ffi_api::*;
pub use json_types::*;
