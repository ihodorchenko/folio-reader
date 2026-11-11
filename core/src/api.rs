//! Safe Rust API of the core: document, layout/structure JSON caches, rendering,
//! search. Used by the CLI and the C ABI (`ffi_api`).

use crate::ffi::*;
use crate::json_types::*;
use crate::structure::{self, Analysis};
use std::collections::HashMap;
use std::ffi::CString;
use std::sync::{Arc, Mutex, MutexGuard};

pub struct Document {
    path: String,
    inner: Mutex<Inner>,
}

struct Inner {
    handle: FPDF_DOCUMENT,
    page_count: i32,
    sizes: Vec<(f64, f64)>,
    analysis: Option<Arc<Analysis>>,
    layout_json: HashMap<i32, Arc<str>>,
    structure_json: Option<Arc<str>>,
    /// The content is vertically mirrored (Quartz print-to-PDF): coordinates
    /// are normalized and the raster is flipped so the text lands on the image.
    y_flip: Option<bool>,
}

// All PDFium access goes under the global mutex (ffi::PDFIUM_LOCK),
// so the document can be safely sent between threads.
unsafe impl Send for Document {}
unsafe impl Sync for Document {}

impl Document {
    pub fn open(path: &str) -> Result<Document, String> {
        let (p, _guard) = pdfium_locked()?;
        let cpath = CString::new(path).map_err(|_| "path contains NUL".to_string())?;
        let handle = unsafe { (p.FPDF_LoadDocument)(cpath.as_ptr(), std::ptr::null()) };
        if handle.is_null() {
            let code = unsafe { (p.FPDF_GetLastError)() };
            return Err(format!(
                "failed to open «{}»: {} (code {})",
                path,
                Pdfium::error_name(code),
                code
            ));
        }
        let page_count = unsafe { (p.FPDF_GetPageCount)(handle) };
        if page_count < 0 {
            unsafe { (p.FPDF_CloseDocument)(handle) };
            return Err("PDFium could not determine the page count".to_string());
        }
        let mut sizes = Vec::with_capacity(page_count as usize);
        for i in 0..page_count {
            let mut sz = FS_SIZEF::default();
            let ok = unsafe { (p.FPDF_GetPageSizeByIndexF)(handle, i, &mut sz) };
            if ok != 0 && sz.width > 0.0 && sz.height > 0.0 {
                sizes.push((sz.width as f64, sz.height as f64));
            } else {
                sizes.push((612.0, 792.0));
            }
        }
        drop(_guard);
        Ok(Document {
            path: path.to_string(),
            inner: Mutex::new(Inner {
                handle,
                page_count,
                sizes,
                analysis: None,
                layout_json: HashMap::new(),
                structure_json: None,
                y_flip: None,
            }),
        })
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    fn lock(&self) -> Result<MutexGuard<'_, Inner>, String> {
        Ok(self.inner.lock().unwrap_or_else(|e| e.into_inner()))
    }

    pub fn page_count(&self) -> Result<i32, String> {
        Ok(self.lock()?.page_count)
    }

    pub fn page_size(&self, page: i32) -> Result<(f64, f64), String> {
        let inner = self.lock()?;
        if page < 0 || page >= inner.page_count {
            return Err(format!(
                "page {} out of range 0..{}",
                page,
                inner.page_count - 1
            ));
        }
        Ok(inner.sizes[page as usize])
    }

    fn ensure_analysis(&self, inner: &mut Inner) -> Result<(), String> {
        if inner.analysis.is_some() {
            return Ok(());
        }
        let (p, _guard) = pdfium_locked()?;
        let analysis = structure::analyze(p, inner.handle)?;
        inner.analysis = Some(Arc::new(analysis));
        Ok(())
    }

    fn compute_y_flip(&self, inner: &mut Inner) -> Result<bool, String> {
        if let Some(v) = inner.y_flip {
            return Ok(v);
        }
        let (p, _guard) = pdfium_locked()?;
        let mut flipped = false;
        if inner.page_count > 0 {
            unsafe {
                let pg = (p.FPDF_LoadPage)(inner.handle, 0);
                if !pg.is_null() {
                    flipped = crate::text::detect_y_flip_page(p, pg);
                    (p.FPDF_ClosePage)(pg);
                }
            }
        }
        inner.y_flip = Some(flipped);
        Ok(flipped)
    }

    pub fn analysis(&self) -> Result<Arc<Analysis>, String> {
        let mut inner = self.lock()?;
        self.ensure_analysis(&mut inner)?;
        Ok(inner
            .analysis
            .as_ref()
            .expect("analysis is set")
            .clone())
    }

    pub fn page_layout_json(&self, page: i32) -> Result<String, String> {
        {
            let inner = self.lock()?;
            if page < 0 || page >= inner.page_count {
                return Err(format!("page {} out of range", page));
            }
            if let Some(s) = inner.layout_json.get(&page) {
                return Ok(s.to_string());
            }
        }
        let analysis = self.analysis()?;
        let layout = analysis
            .layouts
            .get(page as usize)
            .ok_or_else(|| format!("no layout for page {}", page))?;
        let json = serde_json::to_string(layout).map_err(|e| format!("JSON: {}", e))?;
        let mut inner = self.lock()?;
        inner.layout_json.insert(page, Arc::from(json.as_str()));
        Ok(json)
    }

    pub fn document_structure_json(&self) -> Result<String, String> {
        {
            let inner = self.lock()?;
            if let Some(s) = &inner.structure_json {
                return Ok(s.to_string());
            }
        }
        let analysis = self.analysis()?;
        let json =
            serde_json::to_string(&analysis.structure).map_err(|e| format!("JSON: {}", e))?;
        let mut inner = self.lock()?;
        inner.structure_json = Some(Arc::from(json.as_str()));
        Ok(json)
    }

    pub fn structure(&self) -> Result<DocumentStructure, String> {
        let analysis = self.analysis()?;
        Ok(analysis.structure.clone())
    }

    pub fn page_layout(&self, page: i32) -> Result<PageLayout, String> {
        let analysis = self.analysis()?;
        analysis
            .layouts
            .get(page as usize)
            .cloned()
            .ok_or_else(|| format!("no layout for page {}", page))
    }

    pub fn search_json(&self, query: &str) -> Result<String, String> {
        let inner = self.lock()?;
        let (p, _guard) = pdfium_locked()?;
        let result = structure::search(p, inner.handle, query, 500)?;
        serde_json::to_string(&result).map_err(|e| format!("JSON: {}", e))
    }

    pub fn search(&self, query: &str) -> Result<SearchResult, String> {
        let inner = self.lock()?;
        let (p, _guard) = pdfium_locked()?;
        structure::search(p, inner.handle, query, 500)
    }

    /// Debug raw page characters (before grouping into words/lines).
    pub fn raw_page_chars(&self, page: i32) -> Result<Vec<crate::text::RawChar>, String> {
        let inner = self.lock()?;
        if page < 0 || page >= inner.page_count {
            return Err(format!("page {} out of range", page));
        }
        let (p, _guard) = pdfium_locked()?;
        unsafe {
            let pg = (p.FPDF_LoadPage)(inner.handle, page);
            if pg.is_null() {
                return Err(format!("failed to load page {}", page));
            }
            let geo = crate::text::page_geometry(p, pg);
            let chars = crate::text::extract_chars(p, pg, &geo);
            (p.FPDF_ClosePage)(pg);
            Ok(chars)
        }
    }

    /// Render a page to BGRA (byte order B,G,R,A), alpha=255, white background.
    pub fn render_page(&self, page: i32, scale: f64) -> Result<RenderOutput, String> {
        if !(scale > 0.0) || !scale.is_finite() {
            return Err("scale must be > 0".to_string());
        }
        let mut inner = self.lock()?;
        if page < 0 || page >= inner.page_count {
            return Err(format!("page {} out of range", page));
        }
        let flip_y = self.compute_y_flip(&mut inner)?;
        let (p, _guard) = pdfium_locked()?;
        unsafe {
            let pg = (p.FPDF_LoadPage)(inner.handle, page);
            if pg.is_null() {
                return Err(format!("failed to load page {}", page));
            }
            let result = render_loaded(p, pg, scale, flip_y);
            (p.FPDF_ClosePage)(pg);
            result
        }
    }
}

pub struct RenderOutput {
    pub width: i32,
    pub height: i32,
    /// BGRA, row 0 is the top row of the image.
    pub bgra: Vec<u8>,
}

/// Row order in the PDFium buffer: `FPDFBitmap` stores the first row at the top,
/// but we verify this empirically in the `render_orientation` test — here rows are
/// copied as is (see the comment in the test).
pub const FLIP_RENDER_ROWS: bool = false;

unsafe fn render_loaded(
    p: &Pdfium,
    page: FPDF_PAGE,
    scale: f64,
    flip_y: bool,
) -> Result<RenderOutput, String> {
    let rotation = (p.FPDFPage_GetRotation)(page).rem_euclid(4);
    let disp_w = (p.FPDF_GetPageWidthF)(page) as f64;
    let disp_h = (p.FPDF_GetPageHeightF)(page) as f64;
    if !(disp_w > 0.0) || !(disp_h > 0.0) {
        return Err("page of zero size".to_string());
    }
    let w = ((disp_w * scale).round() as i32).max(1);
    let h = ((disp_h * scale).round() as i32).max(1);
    if w as i64 * h as i64 > 400_000_000 {
        return Err("raster buffer too large (scale?)".to_string());
    }
    let bitmap = (p.FPDFBitmap_CreateEx)(w, h, FPDFBitmap_BGRA, std::ptr::null_mut(), 0);
    if bitmap.is_null() {
        return Err("failed to create bitmap".to_string());
    }
    (p.FPDFBitmap_FillRect)(bitmap, 0, 0, w, h, 0xFFFF_FFFF);
    (p.FPDF_RenderPageBitmap)(bitmap, page, 0, 0, w, h, rotation, FPDF_ANNOT);

    let stride = (p.FPDFBitmap_GetStride)(bitmap) as usize;
    let buf = (p.FPDFBitmap_GetBuffer)(bitmap) as *const u8;
    let row_bytes = (w as usize) * 4;
    let mut out = vec![0u8; row_bytes * h as usize];
    if buf.is_null() || stride < row_bytes {
        (p.FPDFBitmap_Destroy)(bitmap);
        return Err("bitmap without a buffer".to_string());
    }
    for y in 0..h as usize {
        let src = buf.add(y * stride);
        let dst_off = y * row_bytes;
        std::ptr::copy_nonoverlapping(src, out.as_mut_ptr().add(dst_off), row_bytes);
    }
    (p.FPDFBitmap_Destroy)(bitmap);

    if FLIP_RENDER_ROWS {
        let mut flipped = vec![0u8; out.len()];
        for y in 0..h as usize {
            let src_off = y * row_bytes;
            let dst_off = (h as usize - 1 - y) * row_bytes;
            flipped[dst_off..dst_off + row_bytes]
                .copy_from_slice(&out[src_off..src_off + row_bytes]);
        }
        out = flipped;
    }
    // For documents with vertically mirrored content we flip the raster:
    // the text coordinates are normalized the same way.
    if flip_y {
        crate::text::flip_rows_bgra(&mut out, w, h);
    }
    // alpha is always 255 (PDFium on a white background usually already does this, but we guarantee it).
    for px in out.chunks_exact_mut(4) {
        px[3] = 255;
    }
    Ok(RenderOutput {
        width: w,
        height: h,
        bgra: out,
    })
}

impl Drop for Document {
    fn drop(&mut self) {
        let inner = match self.inner.get_mut() {
            Ok(i) => i,
            Err(_) => return,
        };
        if !inner.handle.is_null() {
            if let Ok((p, _guard)) = pdfium_locked() {
                unsafe { (p.FPDF_CloseDocument)(inner.handle) };
            }
            inner.handle = std::ptr::null_mut();
        }
    }
}
