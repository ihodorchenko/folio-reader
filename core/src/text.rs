//! Page character extraction via PDFium and grouping:
//! characters → words → lines → blocks.
//!
//! Coordinates are PDF points, origin top-left, y down, taking /Rotate
//! into account (CONTRACT §2). Characters inside a page live in PDF user space (origin
//! bottom-left); here they are immediately converted to display orientation.

use crate::ffi::*;
use crate::json_types::*;
use std::collections::HashMap;

/// A page character in display coordinates (top-left origin).
#[derive(Clone, Debug)]
pub struct RawChar {
    pub ch: char,
    pub ws: bool,
    pub bbox: Rect,
    pub baseline: f64,
    pub size: f64,
    pub bold: bool,
    pub italic: bool,
    pub mono: bool,
    pub math: bool,
    pub font: String,
    pub generated: bool,
    /// Scale of the effective PDFium char matrix (hypot(a,b)); debug info.
    pub matrix_scale: f64,
    /// The text is drawn with a negative d in the matrix (vertically mirrored).
    pub matrix_flip: bool,
    /// Word boundary "after this character" from PDFium-generated spaces
    /// (their position in the char box is unreliable, but the stream order is reliable).
    pub break_after: bool,
}

/// A line + internal features for the classifier.
#[derive(Clone, Debug)]
pub struct RawLine {
    pub page: i32,
    pub page_w: f64,
    pub page_h: f64,
    pub line: Line,
    pub size: f64,
    pub bold_ratio: f64,
    pub italic_ratio: f64,
    pub mono_ratio: f64,
    pub math_ratio: f64,
    pub char_count: usize,
    pub norm_text: String,
    pub zone: Zone,
}

impl RawLine {
    pub fn text(&self) -> &str {
        &self.line.text
    }
    pub fn bbox(&self) -> Rect {
        self.line.bbox
    }
    pub fn first_word(&self) -> &str {
        self.line.words.first().map(|w| w.text.as_str()).unwrap_or("")
    }
    pub fn char_len(&self) -> usize {
        self.line.text.chars().count()
    }
    pub fn bold(&self) -> bool {
        self.bold_ratio >= 0.6
    }
    pub fn italic(&self) -> bool {
        self.italic_ratio >= 0.6
    }
}

/// Raw page data before document-level classification (after font-size
/// normalization — see [`estimate_size_scale`]).
#[derive(Clone, Debug)]
pub struct PageRaw {
    pub index: i32,
    pub width: f64,
    pub height: f64,
    pub rotation: i32,
    pub body_font_size: f64,
    pub lines: Vec<RawLine>,
    pub tagged: bool,
    /// Heading tags (/H, /H1../H6) from the structure tree in traversal order.
    pub tag_headings: Vec<i32>,
}

#[derive(Clone, Debug, Default)]
pub struct FontStyle {
    pub name: String,
    pub bold: bool,
    pub italic: bool,
    pub mono: bool,
    pub math: bool,
}

fn is_bold_font(name: &str, flags: i32, weight: i32) -> bool {
    if flags & (1 << 18) != 0 || weight >= 600 {
        return true;
    }
    let n = name.to_ascii_lowercase();
    const NEEDLES: &[&str] = &[
        "bold", "medi", "black", "heavy", "demi", "semibold", "cmbx", "ptmb", "helveticab",
        "arialbd", "arial-bold", "times-bold", "timesbd", "notosans-bold", "notoserif-bold",
        "dejavusans-bold", "dejavuserif-bold", "liberationsans-bold", "liberationserif-bold",
    ];
    NEEDLES.iter().any(|s| n.contains(s))
}

fn is_italic_font(name: &str, flags: i32) -> bool {
    if flags & (1 << 6) != 0 {
        return true;
    }
    let n = name.to_ascii_lowercase();
    const NEEDLES: &[&str] = &[
        "italic", "oblique", "itals", "cmti", "cmmi", "cmsl", "ptmi", "ariali", "timesi",
        "notosans-italic", "notoserif-italic", "dejavusans-oblique", "liberationsans-italic",
        "liberationserif-italic",
    ];
    NEEDLES.iter().any(|s| n.contains(s))
}

fn is_mono_font(name: &str, flags: i32) -> bool {
    if flags & 1 != 0 {
        return true;
    }
    let n = name.to_ascii_lowercase();
    const NEEDLES: &[&str] = &[
        "mono", "courier", "menlo", "consolas", "cmtt", "typewriter", "code", "inconsolata",
        "sourcecode", "jetbrains", "firacode", "sfmono", "lucidaconsole", "dejavusansmono",
    ];
    NEEDLES.iter().any(|s| n.contains(s))
}

fn is_math_font(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    const NEEDLES: &[&str] = &[
        "cmmi", "cmsy", "cmex", "cmbsy", "msam", "msbm", "eufm", "eusm", "eusb", "wasy", "rsfs",
        "math", "symbol", "stix", "asana", "euler", "mtmi", "mt-ex", "lmromanmath",
        "latinmodern-math", "xitsmath", "texgyre",
    ];
    NEEDLES.iter().any(|s| n.contains(s))
}

pub fn style_from(name: &str, flags: i32, weight: i32) -> FontStyle {
    FontStyle {
        name: name.to_string(),
        bold: is_bold_font(name, flags, weight),
        italic: is_italic_font(name, flags),
        mono: is_mono_font(name, flags),
        math: is_math_font(name),
    }
}

// ---------------------------------------------------------------------------
// Geometry / rotation
// ---------------------------------------------------------------------------

/// A point from unrotated PDF space (origin top-left, y down) to display space.
pub fn rotate_point(x: f64, y: f64, rotation: i32, raw_w: f64, raw_h: f64) -> (f64, f64) {
    match rotation.rem_euclid(4) {
        1 => (raw_h - y, x),
        2 => (raw_w - x, raw_h - y),
        3 => (y, raw_w - x),
        _ => (x, y),
    }
}

/// Rectangle into display orientation (rotation around the sheet center).
pub fn rotate_rect(r: Rect, rotation: i32, raw_w: f64, raw_h: f64) -> Rect {
    match rotation.rem_euclid(4) {
        1 => Rect::new(raw_h - r.y - r.h, r.x, r.h, r.w),
        2 => Rect::new(raw_w - r.x - r.w, raw_h - r.y - r.h, r.w, r.h),
        3 => Rect::new(r.y, raw_w - r.x - r.w, r.h, r.w),
        _ => r,
    }
}

fn median(mut v: Vec<f64>) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.retain(|x| x.is_finite());
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) * 0.5
    }
}

/// Most frequent size (mode), weighted by character count.
pub fn mode_size(chars: &[RawChar]) -> f64 {
    let mut counts: HashMap<i32, usize> = HashMap::new();
    for c in chars {
        if c.size > 0.5 {
            *counts.entry((c.size * 2.0).round() as i32).or_default() += 1;
        }
    }
    counts
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)))
        .map(|(k, _)| k as f64 / 2.0)
        .unwrap_or(0.0)
}

/// Vertically mirror page characters (for PDFs drawn with a
/// negative d in the text matrix: Quartz/macOS print-to-PDF from a flipped view).
/// The coordinates become "visual" (as on a normally laid-out sheet).
pub fn flip_chars_y(chars: &mut [RawChar], page_h: f64) {
    if page_h <= 0.0 {
        return;
    }
    for c in chars.iter_mut() {
        let y = page_h - c.bbox.y - c.bbox.h;
        c.bbox = Rect::new(c.bbox.x, y, c.bbox.w, c.bbox.h);
        c.baseline = page_h - c.baseline;
    }
}

/// Detect that the text content is drawn vertically mirrored
/// (negative `d` in the char matrix — Quartz/AppKit from a flipped view).
/// We look at the sign of `d` for most characters: this is more reliable than the
/// position of the first character and does not depend on where the text is on the page.
pub fn detect_y_flip_page(p: &Pdfium, page: FPDF_PAGE) -> bool {
    let geo = page_geometry(p, page);
    if geo.height <= 1.0 {
        return false;
    }
    unsafe {
        let tp = (p.FPDFText_LoadPage)(page);
        if tp.is_null() {
            return false;
        }
        let n = (p.FPDFText_CountChars)(tp);
        let mut flipped = 0usize;
        let mut upright = 0usize;
        let mut i = 0;
        while i < n && i < 600 {
            let uni = (p.FPDFText_GetUnicode)(tp, i);
            let ws = char::from_u32(uni)
                .map(|c| c.is_whitespace())
                .unwrap_or(true);
            if !ws {
                let mut mat = FS_MATRIX::default();
                if (p.FPDFText_GetMatrix)(tp, i, &mut mat) != 0 {
                    let vert = ((mat.c * mat.c + mat.d * mat.d) as f64).sqrt();
                    if vert > 0.05 {
                        if mat.d < -1e-6 {
                            flipped += 1;
                        } else if mat.d > 1e-6 {
                            upright += 1;
                        }
                    }
                }
            }
            i += 1;
        }
        (p.FPDFText_ClosePage)(tp);
        flipped > upright && flipped >= 5
    }
}

/// Vertically mirror a BGRA buffer by rows (for y-flipped documents).
pub fn flip_rows_bgra(data: &mut [u8], width: i32, height: i32) {
    if width <= 0 || height <= 0 {
        return;
    }
    let row = width as usize * 4;
    let h = height as usize;
    if data.len() < row * h {
        return;
    }
    for y in 0..h / 2 {
        let a = y * row;
        let b = (h - 1 - y) * row;
        for i in 0..row {
            data.swap(a + i, b + i);
        }
    }
}

// ---------------------------------------------------------------------------
// Page extraction
// ---------------------------------------------------------------------------

pub struct PageGeometry {
    pub rotation: i32,
    pub width: f64,
    pub height: f64,
    pub raw_w: f64,
    pub raw_h: f64,
    /// PDF-space coordinates of the left/top edge (unrotated origin).
    pub bx0: f64,
    pub by_top: f64,
}

pub fn page_geometry(p: &Pdfium, page: FPDF_PAGE) -> PageGeometry {
    unsafe {
        let rotation = (p.FPDFPage_GetRotation)(page);
        let disp_w = (p.FPDF_GetPageWidthF)(page) as f64;
        let disp_h = (p.FPDF_GetPageHeightF)(page) as f64;
        let mut bb = FS_RECTF::default();
        let ok = (p.FPDF_GetPageBoundingBox)(page, &mut bb);
        let has_bb = ok != 0 && bb.right > bb.left && bb.top > bb.bottom;
        let (bx0, by_top, raw_w, raw_h) = if has_bb {
            (
                bb.left as f64,
                bb.top as f64,
                (bb.right - bb.left) as f64,
                (bb.top - bb.bottom) as f64,
            )
        } else if rotation.rem_euclid(2) == 1 {
            (0.0, disp_h, disp_w, disp_h)
        } else {
            (0.0, disp_h, disp_w, disp_h)
        };
        PageGeometry {
            rotation: rotation.rem_euclid(4),
            width: disp_w,
            height: disp_h,
            raw_w,
            raw_h,
            bx0,
            by_top,
        }
    }
}

/// Raw page characters without line grouping.
///
/// `size` here is what PDFium returned (`FPDFText_GetFontSize`). For some
/// PDFs (e.g. Quartz exports with a scale in the text matrix) it is 1.0 and
/// does not match the visual font size — then `estimate_size_scale` provides
/// a correction factor, and lines are built from the corrected sizes.
#[derive(Clone, Debug)]
pub struct PageExtract {
    pub index: i32,
    pub width: f64,
    pub height: f64,
    pub rotation: i32,
    pub chars: Vec<RawChar>,
    pub tagged: bool,
    pub tag_headings: Vec<i32>,
}

/// Full page extraction into characters + structure tree.
///
/// Call with `page` loaded; it loads/closes the text page and
/// the structure tree itself.
pub fn extract_page_chars(p: &Pdfium, page: FPDF_PAGE, index: i32) -> Result<PageExtract, String> {
    let geo = page_geometry(p, page);
    let (tagged, tag_headings) = crate::structure::collect_struct_heading_tags(p, page);
    let chars = unsafe { extract_chars(p, page, &geo) };
    Ok(PageExtract {
        index,
        width: geo.width,
        height: geo.height,
        rotation: geo.rotation,
        chars,
        tagged,
        tag_headings,
    })
}

pub unsafe fn extract_chars(p: &Pdfium, page: FPDF_PAGE, geo: &PageGeometry) -> Vec<RawChar> {
    let mut out = Vec::new();
    let text_page = (p.FPDFText_LoadPage)(page);
    if text_page.is_null() {
        return out;
    }
    let count = (p.FPDFText_CountChars)(text_page);
    if count <= 0 {
        (p.FPDFText_ClosePage)(text_page);
        return out;
    }
    let mut i = 0;
    let mut generated_break = false;
    while i < count {
        let mut uni = (p.FPDFText_GetUnicode)(text_page, i);
        let mut consumed = 1;
        if (0xD800..0xDC00).contains(&uni) && i + 1 < count {
            let lo = (p.FPDFText_GetUnicode)(text_page, i + 1);
            if (0xDC00..0xE000).contains(&lo) {
                uni = 0x10000 + ((uni - 0xD800) << 10) + (lo - 0xDC00);
                consumed = 2;
            }
        }
        i += consumed;

        let ch = match char::from_u32(uni) {
            Some(c) => c,
            None => continue,
        };
        let mut left = 0.0f64;
        let mut right = 0.0f64;
        let mut bottom = 0.0f64;
        let mut top = 0.0f64;
        let ok = (p.FPDFText_GetCharBox)(
            text_page,
            i - consumed,
            &mut left,
            &mut right,
            &mut bottom,
            &mut top,
        );
        if ok == 0 {
            continue;
        }
        let mut size = (p.FPDFText_GetFontSize)(text_page, i - consumed);
        if !(size > 0.0) || !size.is_finite() {
            continue;
        }
        // Effective font size = font size × char-matrix scale: some PDFs
        // (Quartz/macOS print-to-PDF) keep Tf=1 and set the size via Tm.
        let mut mat = FS_MATRIX::default();
        let mscale = if (p.FPDFText_GetMatrix)(text_page, i - consumed, &mut mat) != 0 {
            let vert = ((mat.c * mat.c + mat.d * mat.d) as f64).sqrt();
            let horiz = ((mat.a * mat.a + mat.b * mat.b) as f64).sqrt();
            if vert > 0.0 && vert.is_finite() {
                vert
            } else if horiz > 0.0 && horiz.is_finite() {
                horiz
            } else {
                1.0
            }
        } else {
            1.0
        };
        if mscale.is_finite() && mscale > 0.01 {
            size *= mscale;
        }
        // Text rotated by 90° (e.g. an arXiv stamp in the margins) breaks
        // line grouping — skip it (angle is the glyph angle in radians).
        let angle = (p.FPDFText_GetCharAngle)(text_page, i - consumed);
        if angle.is_finite() && angle.abs() > 0.35 {
            continue;
        }
        let ws = ch.is_whitespace();
        if !left.is_finite() || !right.is_finite() || !top.is_finite() || !bottom.is_finite() {
            continue;
        }

        // PDF user space (origin bottom-left) → unrotated display (top-left).
        let x_un = left - geo.bx0;
        let y_un_top = geo.by_top - top;
        let y_un_bottom = geo.by_top - bottom;
        let rect_un = Rect::from_ltrb(x_un, y_un_top, right - geo.bx0, y_un_bottom);

        let mut ox = 0.0f64;
        let mut oy = 0.0f64;
        let baseline_un = if (p.FPDFText_GetCharOrigin)(text_page, i - consumed, &mut ox, &mut oy) != 0
            && oy.is_finite()
        {
            geo.by_top - oy
        } else {
            rect_un.bottom()
        };
        let (_, baseline) = rotate_point(
            rect_un.center_x(),
            baseline_un,
            geo.rotation,
            geo.raw_w,
            geo.raw_h,
        );
        let rect = rotate_rect(rect_un, geo.rotation, geo.raw_w, geo.raw_h);

        // Keep spaces even with zero area: PDFium often returns an empty bbox
        // for a space, but it must still break words. Other junk
        // (generated line breaks) is dropped.
        if !ws && rect.area() <= 0.0 {
            continue;
        }
        // Do not show characters outside the cropbox.
        if rect.center_x() < -2.0
            || rect.center_x() > geo.width + 2.0
            || rect.center_y() < -2.0
            || rect.center_y() > geo.height + 2.0
        {
            continue;
        }

        let mut flags = 0i32;
        let mut fbuf = [0u8; 256];
        let flen = (p.FPDFText_GetFontInfo)(
            text_page,
            i - consumed,
            fbuf.as_mut_ptr() as *mut std::ffi::c_void,
            fbuf.len() as std::ffi::c_ulong,
            &mut flags,
        );
        let name = if flen > 0 {
            if flen as usize > fbuf.len() {
                let mut big = vec![0u8; flen as usize];
                let l2 = (p.FPDFText_GetFontInfo)(
                    text_page,
                    i - consumed,
                    big.as_mut_ptr() as *mut std::ffi::c_void,
                    flen as std::ffi::c_ulong,
                    &mut flags,
                );
                decode_font_name(&big[..(l2.max(0) as usize).min(big.len())])
            } else {
                decode_font_name(&fbuf[..(flen as usize).min(fbuf.len())])
            }
        } else {
            String::new()
        };
        let weight = (p.FPDFText_GetFontWeight)(text_page, i - consumed);
        let generated = (p.FPDFText_IsGenerated)(text_page, i - consumed) > 0;
        // Generated spaces/line breaks are only a word-boundary marker:
        // their x-coordinate may coincide with or overlap the neighboring glyph.
        if generated && ws {
            generated_break = true;
            continue;
        }
        if generated_break {
            if let Some(last) = out.last_mut() {
                last.break_after = true;
            }
            generated_break = false;
        }
        let style = style_from(&name, flags, weight);

        out.push(RawChar {
            ch,
            ws,
            bbox: rect,
            baseline,
            size: round_f(size, 2),
            bold: style.bold,
            italic: style.italic,
            mono: style.mono,
            math: style.math,
            font: style.name,
            generated,
            matrix_scale: mscale,
            matrix_flip: mat.d < -1e-6,
            break_after: false,
        });
    }
    (p.FPDFText_ClosePage)(text_page);
    out
}

/// Font name from `FPDFText_GetFontInfo`: per the vendor library header the buffer
/// is UTF-8 (in older PDFium builds — UTF-16LE), so we detect the encoding
/// by the zero high bytes.
fn decode_font_name(bytes: &[u8]) -> String {
    let nul = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let b = &bytes[..nul];
    let utf16 = b.len() >= 4
        && b.len() % 2 == 0
        && b.iter().skip(1).step_by(2).all(|&x| x == 0)
        && b.first().map(|&x| x != 0).unwrap_or(false);
    if utf16 {
        Pdfium::utf16le(bytes)
    } else {
        String::from_utf8_lossy(b).to_string()
    }
}

fn round_f(v: f64, digits: u32) -> f64 {
    if !v.is_finite() {
        return 0.0;
    }
    let m = 10f64.powi(digits as i32);
    (v * m).round() / m
}

// ---------------------------------------------------------------------------
// Characters → lines
// ---------------------------------------------------------------------------

pub fn build_lines(
    chars: &[RawChar],
    page: i32,
    page_w: f64,
    page_h: f64,
    body_size: f64,
) -> Vec<RawLine> {
    if chars.is_empty() {
        return Vec::new();
    }
    let mut sorted: Vec<usize> = (0..chars.len()).collect();
    sorted.sort_by(|&a, &b| {
        let ba = chars[a].baseline;
        let bb = chars[b].baseline;
        ba.partial_cmp(&bb)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                chars[a]
                    .bbox
                    .x
                    .partial_cmp(&chars[b].bbox.x)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    let mut out: Vec<RawLine> = Vec::new();
    let mut i = 0;
    while i < sorted.len() {
        let base = chars[sorted[i]].baseline;
        let mut row_size = chars[sorted[i]].size;
        let mut j = i + 1;
        while j < sorted.len() {
            let c = &chars[sorted[j]];
            // Baseline tolerance: superscript/subscript (pnö) must
            // fall into the line, but neighboring lines must not.
            let tol = (0.5 * row_size.min(14.0))
                .max(0.45 * body_size.max(1.0))
                .max(1.2);
            if (c.baseline - base).abs() <= tol {
                row_size = row_size.max(c.size);
                j += 1;
            } else {
                break;
            }
        }
        // Within a row characters must go strictly by x: after sorting by
        // baseline+x (for superscripts) the x order is not monotonic.
        let mut row: Vec<usize> = sorted[i..j].to_vec();
        row.sort_by(|&a, &b| {
            chars[a]
                .bbox
                .x
                .partial_cmp(&chars[b].bbox.x)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        // Split the row into fragments at large horizontal gaps
        // (two columns / table cells must not be glued together).
        let em = median(row.iter().map(|&k| chars[k].size).collect());
        let split_thresh = (1.7 * em).max(8.0);
        let mut frag: Vec<usize> = Vec::new();
        for &k in &row {
            let c = &chars[k];
            if let Some(&prev) = frag.last() {
                let prev_c = &chars[prev];
                let gap = c.bbox.x - prev_c.bbox.right();
                if gap > split_thresh {
                    if let Some(line) = build_line(&frag, chars, page, page_w, page_h, body_size) {
                        out.push(line);
                    }
                    frag.clear();
                }
            }
            frag.push(k);
        }
        if let Some(line) = build_line(&frag, chars, page, page_w, page_h, body_size) {
            out.push(line);
        }
        i = j;
    }

    // Reading order: bands by y, then by x within a band (two-column layout).
    let band = (0.5 * body_size).max(1.5);
    out.sort_by(|a, b| {
        let ka = (a.line.bbox.y / band).round() as i64;
        let kb = (b.line.bbox.y / band).round() as i64;
        ka.cmp(&kb).then_with(|| {
            a.line
                .bbox
                .x
                .partial_cmp(&b.line.bbox.x)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
    });
    out
}

fn build_line(
    idxs: &[usize],
    chars: &[RawChar],
    page: i32,
    page_w: f64,
    page_h: f64,
    body_size: f64,
) -> Option<RawLine> {
    if idxs.is_empty() {
        return None;
    }
    let mut idxs: Vec<usize> = idxs.to_vec();
    idxs.sort_by(|&a, &b| {
        chars[a]
            .bbox
            .x
            .partial_cmp(&chars[b].bbox.x)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let visible: Vec<usize> = idxs.iter().copied().filter(|&k| !chars[k].ws).collect();
    if visible.is_empty() {
        return None;
    }
    let em = median(visible.iter().map(|&k| chars[k].size).collect());
    let em = if em > 0.0 { em } else { body_size.max(1.0) };

    // Words.
    let mut words: Vec<Word> = Vec::new();
    let mut cur: Vec<usize> = Vec::new();
    let push_word = |cur: &mut Vec<usize>, words: &mut Vec<Word>| {
        if cur.is_empty() {
            return;
        }
        let mut text = String::new();
        let mut bbox = Rect::default();
        let mut first = true;
        let mut bold_n = 0usize;
        let mut italic_n = 0usize;
        let mut chars_n = 0usize;
        let mut font_counts: HashMap<&str, usize> = HashMap::new();
        let mut sizes: Vec<f64> = Vec::new();
        for &k in cur.iter() {
            let c = &chars[k];
            text.push(c.ch);
            bbox = if first {
                first = false;
                c.bbox
            } else {
                bbox.union(c.bbox)
            };
            chars_n += 1;
            if c.bold {
                bold_n += 1;
            }
            if c.italic {
                italic_n += 1;
            }
            *font_counts.entry(c.font.as_str()).or_default() += 1;
            sizes.push(c.size);
        }
        let font = font_counts
            .into_iter()
            .max_by_key(|&(_, n)| n)
            .map(|(f, _)| f.to_string())
            .unwrap_or_default();
        words.push(Word {
            text,
            bbox,
            size: round_f(median(sizes), 1),
            bold: chars_n > 0 && bold_n * 2 >= chars_n,
            italic: chars_n > 0 && italic_n * 2 >= chars_n,
            font,
        });
        cur.clear();
    };

    let mut prev_right = f64::NAN;
    let mut prev_size = em;
    for &k in &idxs {
        let c = &chars[k];
        if c.ws {
            push_word(&mut cur, &mut words);
            prev_right = f64::NAN;
            continue;
        }
        if !cur.is_empty() {
            let prev = &chars[*cur.last().unwrap()];
            let forced = prev.break_after;
            let gap = c.bbox.x - prev_right;
            let thresh = (0.24 * em).max(0.4);
            let size_jump = (c.size - prev_size).abs() > 0.75 * em.max(1.0);
            if forced || (gap.is_finite() && (gap > thresh || size_jump)) {
                push_word(&mut cur, &mut words);
            }
        }
        cur.push(k);
        prev_right = c.bbox.right();
        prev_size = c.size;
    }
    push_word(&mut cur, &mut words);
    if words.is_empty() {
        return None;
    }

    let mut bbox = Rect::default();
    let mut first = true;
    let mut baselines: Vec<f64> = Vec::new();
    let mut bold_n = 0usize;
    let mut italic_n = 0usize;
    let mut mono_n = 0usize;
    let mut math_n = 0usize;
    let mut sizes: Vec<f64> = Vec::new();
    for &k in &visible {
        let c = &chars[k];
        bbox = if first {
            first = false;
            c.bbox
        } else {
            bbox.union(c.bbox)
        };
        baselines.push(c.baseline);
        if c.bold {
            bold_n += 1;
        }
        if c.italic {
            italic_n += 1;
        }
        if c.mono {
            mono_n += 1;
        }
        if c.math {
            math_n += 1;
        }
        sizes.push(c.size);
    }
    let n = visible.len() as f64;
    let text = words
        .iter()
        .map(|w| w.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let size = median(sizes);
    let line = Line {
        bbox,
        text,
        baseline_y: round_f(median(baselines), 2),
        words,
    };
    let norm_text = normalize_for_repeat(&line.text);
    Some(RawLine {
        page,
        page_w,
        page_h,
        size: round_f(size, 1),
        bold_ratio: bold_n as f64 / n,
        italic_ratio: italic_n as f64 / n,
        mono_ratio: mono_n as f64 / n,
        math_ratio: math_n as f64 / n,
        char_count: visible.len(),
        norm_text,
        zone: Zone::of(&line.bbox, page_h),
        line,
    })
}

/// Text normalization for finding repeated headers/footers: lowercase,
/// any numbers → `#`, whitespace collapsed.
pub fn normalize_for_repeat(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_space = false;
    let mut prev_digit = false;
    for ch in s.trim().chars() {
        if ch.is_numeric() {
            if !prev_digit {
                out.push('#');
            }
            prev_digit = true;
            prev_space = false;
        } else {
            prev_digit = false;
            if ch.is_whitespace() {
                if !prev_space {
                    out.push(' ');
                    prev_space = true;
                }
            } else {
                prev_space = false;
                for lc in ch.to_lowercase() {
                    out.push(lc);
                }
            }
        }
    }
    out.trim().to_string()
}

// ---------------------------------------------------------------------------
// Lines (already classified) → blocks
// ---------------------------------------------------------------------------

use crate::classify::ClassifiedLine;

/// Block draft: level/id are assigned later at the document level.
#[derive(Clone, Debug)]
pub struct BlockDraft {
    pub kind: BlockKind,
    pub lines: Vec<RawLine>,
    pub heading_score: f64,
    pub numbered_depth: Option<i32>,
    pub bbox: Rect,
    pub em: f64,
    pub is_title: bool,
    /// 1..6 for headings, 0 for others; assigned at the document level.
    pub level: i32,
    /// heuristic | tagged | outline (for headings).
    pub source: String,
}

impl BlockDraft {
    fn last_line(&self) -> &RawLine {
        self.lines.last().expect("draft has at least one line")
    }
    fn last_marker(&self) -> bool {
        starts_with_list_marker(self.last_line().first_word())
    }
}

fn starts_with_list_marker(word: &str) -> bool {
    let w = word.trim();
    if w.is_empty() {
        return false;
    }
    let mut cs = w.chars();
    match cs.next() {
        Some(c) if matches!(c, '•' | '◦' | '▪' | '●' | '–' | '-' | '*' | '·' | '—') => true,
        _ => {
            // "1." "a)" "(1)" — the marker is a separate word
            let t: String = w.chars().filter(|c| c.is_ascii()).collect();
            if t.len() >= 2 && t.len() <= 4 {
                let b = t.as_bytes();
                if b[0].is_ascii_digit() || b[0].is_ascii_alphabetic() {
                    matches!(b[b.len() - 1], b'.' | b')')
                        && b[1..b.len() - 1].iter().all(|x| x.is_ascii_digit() || x.is_ascii_alphabetic())
                } else {
                    false
                }
            } else {
                false
            }
        }
    }
}

fn style_close(a: &RawLine, b: &RawLine) -> bool {
    (a.size - b.size).abs() <= (0.08 * a.size).max(0.6)
        && a.bold() == b.bold()
        && a.italic() == b.italic()
        && (a.mono_ratio > 0.5) == (b.mono_ratio > 0.5)
}

/// Group classified lines into blocks.
///
/// Lines of the same column/paragraph are glued together, headings are not glued to body,
/// each bulleted list item is a separate block.
pub fn group_blocks(lines: Vec<ClassifiedLine>, body_size: f64) -> Vec<BlockDraft> {
    let mut order: Vec<usize> = (0..lines.len()).collect();
    order.sort_by(|&a, &b| {
        let la = &lines[a].raw;
        let lb = &lines[b].raw;
        la.line
            .bbox
            .y
            .partial_cmp(&lb.line.bbox.y)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                la.line
                    .bbox
                    .x
                    .partial_cmp(&lb.line.bbox.x)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    let mut drafts: Vec<BlockDraft> = Vec::new();
    for idx in order {
        let cl = &lines[idx];
        let raw = &cl.raw;
        let mut best: Option<(usize, f64)> = None; // (draft, gap)
        for (di, d) in drafts.iter().enumerate() {
            if d.is_title {
                continue;
            }
            if !compatible_kind(d, cl) {
                continue;
            }
            let last = d.last_line();
            let em = d.em.max(raw.size).max(body_size * 0.8);
            let gap = raw.line.bbox.y - d.bbox.bottom();
            let merge_gap = match d.kind {
                BlockKind::Heading => 0.8 * em,
                BlockKind::Header | BlockKind::Footer => 0.6 * em,
                BlockKind::Formula => 2.0 * em,
                _ => 1.7 * em,
            };
            if gap < -0.75 * raw.line.bbox.h || gap > merge_gap {
                continue;
            }
            if !style_close(last, raw) {
                continue;
            }
            if !xdjacent(&d.bbox, &raw.line.bbox) {
                continue;
            }
            // A new list item is a new block.
            if d.kind == BlockKind::List
                && starts_with_list_marker(raw.first_word())
                && d.last_marker()
            {
                continue;
            }
            // A heading of the same style is merged only if it is very close.
            if d.kind == BlockKind::Heading && gap > 0.8 * em {
                continue;
            }
            let score = gap.abs();
            if best.map(|(_, s)| score < s).unwrap_or(true) {
                best = Some((di, score));
            }
        }

        match best {
            Some((di, _)) => {
                let d = &mut drafts[di];
                d.bbox = d.bbox.union(raw.line.bbox);
                d.em = d.em.max(raw.size);
                if d.kind == BlockKind::Heading {
                    if let Some(h) = &cl.heading {
                        if h.score > d.heading_score {
                            d.heading_score = h.score;
                            d.numbered_depth = h.numbered_depth;
                        }
                    }
                }
                d.lines.push(raw.clone());
            }
            None => {
                let kind = cl.kind;
                let is_heading = kind == BlockKind::Heading;
                drafts.push(BlockDraft {
                    kind,
                    lines: vec![raw.clone()],
                    heading_score: if is_heading {
                        cl.heading.as_ref().map(|h| h.score).unwrap_or(0.0)
                    } else {
                        0.0
                    },
                    numbered_depth: if is_heading {
                        cl.heading.as_ref().and_then(|h| h.numbered_depth)
                    } else {
                        None
                    },
                    bbox: raw.line.bbox,
                    em: raw.size,
                    is_title: false,
                    level: 0,
                    source: String::new(),
                });
            }
        }
    }

    for d in drafts.iter_mut() {
        d.lines.sort_by(|a, b| {
            a.line
                .baseline_y
                .partial_cmp(&b.line.baseline_y)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    a.line
                        .bbox
                        .x
                        .partial_cmp(&b.line.bbox.x)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        });
    }

    // Single marker characters (footnotes «∗», «† ‡») are not counted as blocks.
    drafts.retain(|d| !is_trivial_marker_block(d));

    // Block reading order.
    let band = (0.5 * body_size).max(1.5);
    drafts.sort_by(|a, b| {
        let ka = (a.bbox.y / band).round() as i64;
        let kb = (b.bbox.y / band).round() as i64;
        ka.cmp(&kb).then_with(|| {
            a.bbox
                .x
                .partial_cmp(&b.bbox.x)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
    });
    drafts
}

/// A block of <=2 characters, all of them markers/punctuation (footnotes), is
/// not a standalone element.
fn is_trivial_marker_block(d: &BlockDraft) -> bool {
    if d.kind != BlockKind::Formula && d.kind != BlockKind::Body {
        return false;
    }
    let text: String = d
        .lines
        .iter()
        .flat_map(|l| l.line.text.chars())
        .filter(|c| !c.is_whitespace())
        .collect();
    let n = text.chars().count();
    if n == 0 || n > 2 {
        return false;
    }
    text.chars().all(|c| !c.is_alphanumeric())
}

fn compatible_kind(d: &BlockDraft, cl: &ClassifiedLine) -> bool {
    if d.kind == cl.kind {
        return true;
    }
    // body lines mistakenly marked quote/reference are not pulled into a body block,
    // but those close to body are allowed (a footnote under a paragraph).
    false
}

fn xdjacent(block: &Rect, line: &Rect) -> bool {
    if line.w <= 0.0 || block.w <= 0.0 {
        return true;
    }
    let r = block.x_overlap_ratio(line);
    if r >= 0.3 {
        return true;
    }
    // a short line centered/right inside the block
    let cx = line.center_x();
    let bcx = block.center_x();
    let half = block.w.max(line.w) * 0.5;
    (cx - bcx).abs() < half && line.w < block.w * 1.2
}

/// Assemble block text from lines: normalized spaces, hyphen joining.
pub fn join_block_text(lines: &[RawLine]) -> String {
    let mut out = String::new();
    for (i, l) in lines.iter().enumerate() {
        let t = l.line.text.trim();
        if t.is_empty() {
            continue;
        }
        if i > 0 && !out.is_empty() {
            let prev_last = out.chars().last();
            let cur_first = t.chars().next();
            let hyphenated = matches!(prev_last, Some('-') | Some('\u{2010}') | Some('\u{00ad}'));
            let lowercase_next = cur_first
                .map(|c| c.is_lowercase() && c.is_alphabetic())
                .unwrap_or(false);
            if hyphenated && lowercase_next {
                while out.ends_with(|c: char| matches!(c, '-' | '\u{2010}' | '\u{00ad}')) {
                    out.pop();
                }
            } else {
                out.push(' ');
            }
        }
        out.push_str(t);
    }
    out
}

/// Dominant block font (by word character count).
pub fn block_font(lines: &[RawLine]) -> Font {
    let mut counts: HashMap<String, (usize, f64, bool, bool)> = HashMap::new();
    for l in lines {
        for w in &l.line.words {
            let e = counts
                .entry(w.font.clone())
                .or_insert((0, w.size, w.bold, w.italic));
            e.0 += w.text.chars().count();
            e.1 = w.size;
            e.2 |= w.bold;
            e.3 |= w.italic;
        }
    }
    let mut best = counts
        .into_iter()
        .max_by_key(|(_, v)| v.0)
        .map(|(name, v)| Font {
            name,
            size: round_f(v.1, 1),
            bold: v.2,
            italic: v.3,
            monospace: false,
        })
        .unwrap_or_default();
    best.monospace = is_mono_font(&best.name, 0) || best.name.to_ascii_lowercase().contains("courier");
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ch(
        c: char,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        size: f64,
        baseline: f64,
        ws: bool,
    ) -> RawChar {
        RawChar {
            ch: c,
            ws,
            bbox: Rect::new(x, y, w, h),
            baseline,
            size,
            bold: false,
            italic: false,
            mono: false,
            math: false,
            font: "Test".to_string(),
            generated: false,
            matrix_scale: 1.0,
            matrix_flip: false,
            break_after: false,
        }
    }

    /// Horizontal characters: each 0.55*size wide.
    fn text_run(s: &str, x0: f64, y: f64, size: f64) -> Vec<RawChar> {
        let mut out = Vec::new();
        let mut x = x0;
        for c in s.chars() {
            let w = if c == ' ' { 0.28 * size } else { 0.55 * size };
            out.push(ch(c, x, y, w, 0.7 * size, size, y + 0.75 * size, c == ' '));
            x += w;
        }
        out
    }

    #[test]
    fn rotate_transforms_for_quarter_turns() {
        // 90° clockwise: (x,y,w,h) → (rawH-y-h, x, h, w)
        let r = rotate_rect(Rect::new(10.0, 20.0, 30.0, 5.0), 1, 600.0, 800.0);
        assert_eq!(r, Rect::new(800.0 - 20.0 - 5.0, 10.0, 5.0, 30.0));
        // 180°
        let r = rotate_rect(Rect::new(10.0, 20.0, 30.0, 5.0), 2, 600.0, 800.0);
        assert_eq!(r, Rect::new(600.0 - 10.0 - 30.0, 800.0 - 20.0 - 5.0, 30.0, 5.0));
        // 270°
        let r = rotate_rect(Rect::new(10.0, 20.0, 30.0, 5.0), 3, 600.0, 800.0);
        assert_eq!(r, Rect::new(20.0, 600.0 - 10.0 - 30.0, 5.0, 30.0));
        // point
        let (x, y) = rotate_point(10.0, 20.0, 1, 600.0, 800.0);
        assert_eq!((x, y), (780.0, 10.0));
    }

    #[test]
    fn groups_words_across_spaces_and_gaps() {
        let mut chars = text_run("Hello world", 10.0, 10.0, 10.0);
        // The second paragraph is noticeably lower.
        chars.extend(text_run("Next line", 10.0, 40.0, 10.0));
        let lines = build_lines(&chars, 0, 612.0, 792.0, 10.0);
        assert_eq!(lines.len(), 2, "two lines: {:?}", lines.iter().map(|l| l.text().to_string()).collect::<Vec<_>>());
        assert_eq!(lines[0].line.text, "Hello world");
        assert_eq!(lines[0].line.words.len(), 2);
        assert_eq!(lines[1].line.text, "Next line");
        assert_eq!(lines[0].zone, Zone::Top);
    }

    #[test]
    fn no_word_split_inside_word() {
        // Cyrillic without spaces is a single word.
        let chars = text_run("Привет", 100.0, 100.0, 11.0);
        let lines = build_lines(&chars, 0, 595.0, 842.0, 11.0);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].line.words.len(), 1);
        assert_eq!(lines[0].line.text, "Привет");
    }

    #[test]
    fn joins_hyphenated_line_break() {
        let mk = |s: &str, y: f64| {
            let chars = text_run(s, 10.0, y, 10.0);
            build_lines(&chars, 0, 612.0, 792.0, 10.0).remove(0)
        };
        let l1 = mk("гифо-", 10.0);
        let l2 = mk("теза", 22.0);
        let text = join_block_text(&[l1, l2]);
        assert_eq!(text, "гифотеза");
    }

    #[test]
    fn normalizes_repeating_text() {
        assert_eq!(normalize_for_repeat("Стр. 3 из 15"), "стр. # из #");
        assert_eq!(normalize_for_repeat("Folio  ·  Демо"), "folio · демо");
    }

    #[test]
    fn flip_chars_y_mirrors_page() {
        let mut chars = text_run("abc", 10.0, 10.0, 10.0);
        let before = chars[0].bbox;
        flip_chars_y(&mut chars, 100.0);
        let after = chars[0].bbox;
        assert!((after.y - (100.0 - before.y - before.h)).abs() < 0.01);
        assert!((chars[0].baseline - (100.0 - (before.y + 7.5))).abs() < 0.01);
    }

    #[test]
    fn flips_bgra_rows() {
        // 2x2, row 0 is red, row 1 is blue (BGRA).
        let mut data = vec![
            0, 0, 255, 255, 0, 0, 255, 255, // top: red
            255, 0, 0, 255, 255, 0, 0, 255, // bottom: blue
        ];
        flip_rows_bgra(&mut data, 2, 2);
        assert_eq!(&data[..4], &[255, 0, 0, 255]);
        assert_eq!(&data[8..12], &[0, 0, 255, 255]);
    }
}
