//! Folio PDF core (`pdfcore`): PDFium-рендер + извлечение структуры страницы,
//! классификация элементов и C ABI для macOS-приложения.
//!
//! См. `pdfreader/CONTRACT.md` — единый источник правды.

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
