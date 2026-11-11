//! C ABI exactly per CONTRACT.md §1. Every extern call is protected by `catch_unwind`,
//! errors go to the thread-local `last_error`.

use crate::api::Document;
use crate::ffi::{self, Pdfium};
use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::sync::OnceLock;

pub struct PcDocument {
    doc: Document,
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_last_error(msg: &str) {
    let clean = msg.replace('\0', " ");
    let c = CString::new(clean).unwrap_or_default();
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = c;
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = CString::new("").unwrap();
    });
}

/// Run the body catching panics; on error record last_error and return fallback.
fn guarded<T>(fallback: T, f: impl FnOnce() -> Result<T, String>) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            set_last_error(&e);
            fallback
        }
        Err(_) => {
            set_last_error("internal pdfcore panic");
            fallback
        }
    }
}

unsafe fn doc_ref<'a>(doc: *const PcDocument) -> Result<&'a Document, String> {
    if doc.is_null() {
        return Err("null PcDocument pointer".to_string());
    }
    Ok(&(*doc).doc)
}

#[no_mangle]
pub extern "C" fn pc_open(path: *const c_char) -> *mut PcDocument {
    guarded(ptr::null_mut(), || {
        if path.is_null() {
            return Err("pc_open: path == NULL".to_string());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "pc_open: path is not UTF-8".to_string())?
            .to_string();
        let doc = Document::open(&path)?;
        clear_last_error();
        Ok(Box::into_raw(Box::new(PcDocument { doc })))
    })
}

#[no_mangle]
pub extern "C" fn pc_close(doc: *mut PcDocument) {
    guarded((), || {
        if doc.is_null() {
            return Ok(());
        }
        let boxed = unsafe { Box::from_raw(doc) };
        drop(boxed);
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn pc_page_count(doc: *const PcDocument) -> i32 {
    guarded(-1, || {
        let d = unsafe { doc_ref(doc)? };
        d.page_count()
    })
}

#[no_mangle]
pub extern "C" fn pc_page_width(doc: *const PcDocument, page: i32) -> f64 {
    guarded(0.0, || {
        let d = unsafe { doc_ref(doc)? };
        Ok(d.page_size(page)?.0)
    })
}

#[no_mangle]
pub extern "C" fn pc_page_height(doc: *const PcDocument, page: i32) -> f64 {
    guarded(0.0, || {
        let d = unsafe { doc_ref(doc)? };
        Ok(d.page_size(page)?.1)
    })
}

#[no_mangle]
pub extern "C" fn pc_render_page(
    doc: *const PcDocument,
    page: i32,
    scale: f64,
    out_w: *mut i32,
    out_h: *mut i32,
    out_bgra: *mut *mut u8,
) -> i32 {
    guarded(-1, || {
        if out_w.is_null() || out_h.is_null() || out_bgra.is_null() {
            return Err("pc_render_page: null out pointer".to_string());
        }
        let d = unsafe { doc_ref(doc)? };
        let rendered = d.render_page(page, scale)?;
        let len = rendered.bgra.len();
        let mem = unsafe { malloc(len) };
        if mem.is_null() {
            return Err("pc_render_page: out of memory".to_string());
        }
        unsafe {
            ptr::copy_nonoverlapping(rendered.bgra.as_ptr(), mem as *mut u8, len);
            *out_w = rendered.width;
            *out_h = rendered.height;
            *out_bgra = mem as *mut u8;
        }
        Ok(0)
    })
}

#[no_mangle]
pub extern "C" fn pc_page_layout_json(doc: *const PcDocument, page: i32) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        let d = unsafe { doc_ref(doc)? };
        let json = d.page_layout_json(page)?;
        Ok(CString::new(json)
            .map_err(|_| "JSON contains NUL".to_string())?
            .into_raw())
    })
}

#[no_mangle]
pub extern "C" fn pc_document_structure_json(doc: *const PcDocument) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        let d = unsafe { doc_ref(doc)? };
        let json = d.document_structure_json()?;
        Ok(CString::new(json)
            .map_err(|_| "JSON contains NUL".to_string())?
            .into_raw())
    })
}

#[no_mangle]
pub extern "C" fn pc_search_json(doc: *const PcDocument, query: *const c_char) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        if query.is_null() {
            return Err("pc_search_json: query == NULL".to_string());
        }
        let q = unsafe { CStr::from_ptr(query) }
            .to_str()
            .map_err(|_| "pc_search_json: query is not UTF-8".to_string())?;
        let d = unsafe { doc_ref(doc)? };
        let json = d.search_json(q)?;
        Ok(CString::new(json)
            .map_err(|_| "JSON contains NUL".to_string())?
            .into_raw())
    })
}

#[no_mangle]
pub extern "C" fn pc_free_buffer(ptr: *mut c_void) {
    if ptr.is_null() {
        return;
    }
    unsafe { free(ptr) };
}

#[no_mangle]
pub extern "C" fn pc_free_json(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[no_mangle]
pub extern "C" fn pc_last_error() -> *const c_char {
    LAST_ERROR.with(|cell| cell.borrow().as_ptr())
}

#[no_mangle]
pub extern "C" fn pc_version() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    VERSION
        .get_or_init(|| {
            CString::new(format!(
                "pdfcore {} / pdfium 8152",
                env!("CARGO_PKG_VERSION")
            ))
            .unwrap_or_default()
        })
        .as_ptr()
}

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
    fn free(ptr: *mut c_void);
}

/// Small check that the FFI table loads (used by tests).
pub fn ffi_available() -> bool {
    ffi::pdfium().is_ok() && ffi::pdfium_locked().is_ok()
}

#[allow(dead_code)]
fn _assert_pdfium_type(_: &Pdfium) {}
