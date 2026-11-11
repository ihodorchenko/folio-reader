//! Document structure: outline from bookmarks, structure tree (tagged PDF),
//! heading levels across the document, title, document metrics, search.

use crate::classify::{classify_line, ClassifiedLine, ClassifyCtx};
use crate::ffi::*;
use crate::json_types::*;
use crate::text::{self, BlockDraft, PageExtract, PageRaw};
use std::collections::HashMap;

pub struct Analysis {
    pub layouts: Vec<PageLayout>,
    pub structure: DocumentStructure,
}

// ---------------------------------------------------------------------------
// Structure tree (tagged PDF)
// ---------------------------------------------------------------------------

/// (whether there is a structure tree, H1..H6 levels in traversal order).
pub fn collect_struct_heading_tags(p: &Pdfium, page: FPDF_PAGE) -> (bool, Vec<i32>) {
    unsafe {
        let tree = (p.FPDF_StructTree_GetForPage)(page);
        if tree.is_null() {
            return (false, Vec::new());
        }
        let mut tags = Vec::new();
        let n = (p.FPDF_StructTree_CountChildren)(tree);
        let mut i = 0;
        while i < n.max(0) && i < 512 {
            let el = (p.FPDF_StructTree_GetChildAtIndex)(tree, i);
            if !el.is_null() {
                walk_struct_element(p, el, 0, &mut tags);
            }
            i += 1;
        }
        (p.FPDF_StructTree_Close)(tree);
        (true, tags)
    }
}

unsafe fn walk_struct_element(
    p: &Pdfium,
    el: FPDF_STRUCTELEMENT,
    depth: i32,
    tags: &mut Vec<i32>,
) {
    if el.is_null() || depth > 48 || tags.len() > 2000 {
        return;
    }
    let ty = Pdfium::read_utf16(|buf, len| (p.FPDF_StructElement_GetType)(el, buf, len));
    if ty.is_empty() {
        let raw = Pdfium::read_utf16(|buf, len| (p.FPDF_StructElement_GetRawType)(el, buf, len));
        if !raw.is_empty() {
            if let Some(level) = tag_heading_level(&raw) {
                tags.push(level);
            }
        }
    } else if let Some(level) = tag_heading_level(&ty) {
        tags.push(level);
    }
    let n = (p.FPDF_StructElement_CountChildren)(el);
    let mut i = 0;
    while i < n.max(0) && i < 512 {
        let child = (p.FPDF_StructElement_GetChildAtIndex)(el, i);
        if !child.is_null() {
            walk_struct_element(p, child, depth + 1, tags);
        }
        i += 1;
    }
}

fn tag_heading_level(tag: &str) -> Option<i32> {
    let t = tag.trim().to_ascii_uppercase();
    if let Some(rest) = t.strip_prefix('H') {
        if rest.is_empty() {
            return Some(1);
        }
        if let Ok(n) = rest.parse::<i32>() {
            if (1..=6).contains(&n) {
                return Some(n);
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Metadata / outline
// ---------------------------------------------------------------------------

pub fn read_meta_title(p: &Pdfium, doc: FPDF_DOCUMENT) -> Option<String> {
    let title = unsafe {
        Pdfium::read_utf16(|buf, len| (p.FPDF_GetMetaText)(doc, b"Title\0".as_ptr() as _, buf, len))
    };
    sanitize_title(&title)
}

pub fn sanitize_title(s: &str) -> Option<String> {
    let t = s.trim().replace(['\r', '\n', '\t'], " ");
    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.chars().count() < 2 || t.chars().count() > 300 {
        return None;
    }
    let low = t.to_lowercase();
    const BAD: &[&str] = &[
        "untitled",
        "без имени",
        "без названия",
        "no title",
        "document",
        "microsoft word",
        "dynamicpdf",
        "unknown",
        "none",
        "-",
    ];
    if BAD.iter().any(|b| low == *b) {
        return None;
    }
    Some(t)
}

pub fn read_outline(p: &Pdfium, doc: FPDF_DOCUMENT) -> Vec<OutlineItem> {
    unsafe {
        let mut items = Vec::new();
        let mut bm = (p.FPDFBookmark_GetFirstChild)(doc, std::ptr::null_mut());
        let mut guard = 0;
        while !bm.is_null() && guard < 2000 {
            items.push(outline_item(p, doc, bm, 0, 0));
            bm = (p.FPDFBookmark_GetNextSibling)(doc, bm);
            guard += 1;
        }
        items
    }
}

unsafe fn outline_item(
    p: &Pdfium,
    doc: FPDF_DOCUMENT,
    bm: FPDF_BOOKMARK,
    level: i32,
    depth: i32,
) -> OutlineItem {
    let title = Pdfium::read_utf16(|buf, len| (p.FPDFBookmark_GetTitle)(bm, buf, len));
    let mut page = -1;
    let mut dest = (p.FPDFBookmark_GetDest)(doc, bm);
    if dest.is_null() {
        let action = (p.FPDFBookmark_GetAction)(bm);
        if !action.is_null() {
            dest = (p.FPDFAction_GetDest)(doc, action);
        }
    }
    if !dest.is_null() {
        let pi = (p.FPDFDest_GetDestPageIndex)(doc, dest);
        if pi >= 0 {
            page = pi;
        }
    }
    let mut children = Vec::new();
    if depth < 32 {
        let mut child = (p.FPDFBookmark_GetFirstChild)(doc, bm);
        let mut guard = 0;
        while !child.is_null() && guard < 2000 {
            children.push(outline_item(p, doc, child, level + 1, depth + 1));
            child = (p.FPDFBookmark_GetNextSibling)(doc, child);
            guard += 1;
        }
    }
    OutlineItem {
        title: title.trim().to_string(),
        page,
        level,
        children,
    }
}

// ---------------------------------------------------------------------------
// Document analysis
// ---------------------------------------------------------------------------

pub fn analyze(p: &Pdfium, doc: FPDF_DOCUMENT) -> Result<Analysis, String> {
    let page_count = unsafe { (p.FPDF_GetPageCount)(doc) };
    if page_count < 0 {
        return Err("PDFium could not determine the page count".to_string());
    }
    let mut extracts: Vec<text::PageExtract> = Vec::with_capacity(page_count as usize);
    for i in 0..page_count {
        let page = unsafe { (p.FPDF_LoadPage)(doc, i) };
        if page.is_null() {
            extracts.push(text::PageExtract {
                index: i,
                width: 0.0,
                height: 0.0,
                rotation: 0,
                chars: Vec::new(),
                tagged: false,
                tag_headings: Vec::new(),
            });
            continue;
        }
        let extracted = text::extract_page_chars(p, page, i);
        unsafe { (p.FPDF_ClosePage)(page) };
        extracts.push(extracted?);
    }

    // Some PDFs (Quartz/macOS print-to-PDF) draw their content vertically
    // mirrored: the page appears upside down in a viewer. This must be
    // taken into account for reading order and header/footer zones.
    let y_flipped = detect_y_flip(&extracts);

    // Character sizes are already converted to visual (fs × char-matrix scale);
    // for vertically mirrored PDFs the coordinates are normalized to "visual" ones.
    let mut pages: Vec<PageRaw> = Vec::with_capacity(extracts.len());
    for mut ex in extracts {
        if y_flipped {
            text::flip_chars_y(&mut ex.chars, ex.height);
        }
        let body = text::mode_size(&ex.chars);
        let lines = text::build_lines(&ex.chars, ex.index, ex.width, ex.height, body);
        pages.push(PageRaw {
            index: ex.index,
            width: ex.width,
            height: ex.height,
            rotation: ex.rotation,
            body_font_size: body,
            lines,
            tagged: ex.tagged,
            tag_headings: ex.tag_headings,
        });
    }

    let doc_body = doc_body_size(&pages);
    let mut ctx = ClassifyCtx::new(page_count, doc_body);
    ctx.header_footer = detect_header_footer(&pages);
    let classified: Vec<Vec<ClassifiedLine>> = pages
        .iter()
        .map(|pg| {
            pg.lines
                .iter()
                .map(|l| classify_line(l, &ctx))
                .collect()
        })
        .collect();

    let mut drafts_per_page: Vec<Vec<BlockDraft>> = Vec::with_capacity(pages.len());
    for (i, lines) in classified.into_iter().enumerate() {
        let body = if pages[i].body_font_size > 0.0 {
            pages[i].body_font_size
        } else {
            doc_body
        };
        drafts_per_page.push(text::group_blocks(lines, body));
    }

    let tagged = pages.iter().any(|pg| pg.tagged);
    let meta_title = read_meta_title(p, doc);
    let heuristic_title = select_title(&mut drafts_per_page, &pages);
    let title = meta_title.or(heuristic_title);
    filter_heading_candidates(&mut drafts_per_page, doc_body);

    let outline = read_outline(p, doc);
    assign_levels(&mut drafts_per_page, &pages, &outline, tagged);

    let mut headings: Vec<Heading> = Vec::new();
    let mut layouts: Vec<PageLayout> = Vec::with_capacity(pages.len());
    let mut cluster_sizes: Vec<f64> = Vec::new();
    for (pi, drafts) in drafts_per_page.iter().enumerate() {
        let page = &pages[pi];
        let mut blocks: Vec<Block> = Vec::with_capacity(drafts.len());
        for (bi, d) in drafts.iter().enumerate() {
            let id = format!("p{}b{}", pi, bi);
            let text = text::join_block_text(&d.lines);
            if d.kind == BlockKind::Heading && !d.is_title {
                cluster_sizes.push((d.lines.first().map(|l| l.size).unwrap_or(0.0) * 2.0).round() / 2.0);
            }
            let confidence = confidence_of(d);
            if d.kind == BlockKind::Heading && d.level > 0 {
                headings.push(Heading {
                    id: id.clone(),
                    page: pi as i32,
                    level: d.level,
                    title: text.clone(),
                    bbox: d.bbox,
                    confidence,
                    source: if d.source.is_empty() {
                        "heuristic".to_string()
                    } else {
                        d.source.clone()
                    },
                });
            }
            blocks.push(Block {
                id,
                kind: d.kind,
                level: d.level,
                text,
                bbox: d.bbox,
                font: text::block_font(&d.lines),
                confidence,
                lines: d.lines.iter().map(|l| l.line.clone()).collect(),
            });
        }
        layouts.push(PageLayout {
            schema: 1,
            index: pi as i32,
            width: page.width,
            height: page.height,
            rotation: page.rotation,
            body_font_size: page.body_font_size.max(if page.lines.is_empty() { 0.0 } else { doc_body * 0.8 }),
            blocks,
        });
    }

    let outline = if outline.is_empty() {
        build_outline_from_headings(&headings)
    } else {
        outline
    };

    cluster_sizes.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
    cluster_sizes.dedup();
    if doc_body > 0.0 && !cluster_sizes.iter().any(|s| (s - doc_body).abs() < 0.25) {
        cluster_sizes.push(doc_body);
    }
    cluster_sizes.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
    cluster_sizes.truncate(8);

    let structure = DocumentStructure {
        schema: 1,
        title,
        page_count,
        tagged,
        outline,
        headings,
        metrics: Metrics {
            body_font_size: r1(doc_body),
            size_clusters: cluster_sizes.into_iter().map(r1).collect(),
            page_count,
            tagged,
        },
    };

    Ok(Analysis { layouts, structure })
}

/// Is the document drawn vertically mirrored? We look at the sign of `d` in
/// the char matrices: it is negative for vertically mirrored text.
fn detect_y_flip(pages: &[PageExtract]) -> bool {
    let mut flipped = 0usize;
    let mut upright = 0usize;
    for pg in pages {
        for c in &pg.chars {
            if c.ws || c.matrix_scale <= 0.01 {
                continue;
            }
            if c.matrix_flip {
                flipped += 1;
            } else {
                upright += 1;
            }
        }
    }
    flipped > upright && flipped >= 5
}

/// Filter out false headings: duplicates, junk from figure captions, too
/// small a font size without numbering, heuristic headings after «References».
fn filter_heading_candidates(drafts: &mut [Vec<BlockDraft>], doc_body: f64) {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for pg in drafts.iter() {
        for d in pg.iter() {
            if d.kind == BlockKind::Heading && !d.is_title {
                let t = normalize_title(&text::join_block_text(&d.lines));
                if !t.is_empty() {
                    *counts.entry(t).or_default() += 1;
                }
            }
        }
    }
    let mut refs_seen = false;
    for pg in drafts.iter_mut() {
        for d in pg.iter_mut() {
            if d.kind != BlockKind::Heading || d.is_title {
                continue;
            }
            let text = text::join_block_text(&d.lines);
            let norm = normalize_title(&text);
            let size = d.lines.first().map(|l| l.size).unwrap_or(0.0);
            let numbered = d.numbered_depth.is_some() || appendix_numbered(&text);
            let references = is_references_title(&norm);
            let duplicated = counts.get(&norm).copied().unwrap_or(0) >= 2;
            let junk_text = !heading_text_ok(&text);
            let too_small = size < doc_body * 1.05 && !numbered;
            let after_refs = refs_seen && !numbered;
            if duplicated || junk_text || too_small || after_refs {
                if std::env::var("PDFCORE_DEBUG").is_ok() {
                    eprintln!(
                        "DROP heading {:?} size={:.2} body={:.2} numbered={} dup={} junk={} small={} after_refs={}",
                        text, size, doc_body, numbered, duplicated, junk_text, too_small, after_refs
                    );
                }
                d.kind = BlockKind::Body;
                d.level = 0;
                d.heading_score = 0.0;
                d.numbered_depth = None;
                d.source.clear();
            }
            if references {
                refs_seen = true;
            }
        }
    }
}

fn heading_text_ok(text: &str) -> bool {
    let t = text.trim();
    let n = t.chars().count();
    if n == 0 || n > 200 {
        return false;
    }
    // When estimating "textiness", ignore the numbering («3.2.1 »).
    let body = strip_leading_numbering(t);
    let bn = body.chars().count();
    let letters = body.chars().filter(|c| c.is_alphabetic()).count();
    if letters < 2 {
        return false;
    }
    // letter ratio: junk from figures/tables is usually "diluted" by symbols
    if bn >= 8 && (letters as f64) / (bn as f64) < 0.55 {
        return false;
    }
    let spaces = t.chars().filter(|c| c.is_whitespace()).count();
    // text stuck together without spaces is almost certainly not a heading
    if spaces == 0 && n > 25 {
        return false;
    }
    if spaces == 0 && camel_transitions(t) >= 2 {
        return false;
    }
    true
}

/// Strip the leading number («1», «3.2.1.», «A.») from a heading.
fn strip_leading_numbering(t: &str) -> &str {
    let mut idx = 0;
    let mut saw_digit = false;
    for (i, c) in t.char_indices() {
        if c.is_ascii_digit() {
            saw_digit = true;
            idx = i + c.len_utf8();
        } else if matches!(c, '.' | ')' | '(' | ' ' | '\t' | '—' | '-' | '–') {
            idx = i + c.len_utf8();
        } else {
            break;
        }
    }
    if saw_digit {
        t[idx..].trim_start()
    } else {
        t
    }
}

/// Number of «lowercase → uppercase» transitions inside tokens: a sign that
/// several captions were glued into one line.
fn camel_transitions(text: &str) -> usize {
    let mut count = 0;
    for token in text.split_whitespace() {
        let chars: Vec<char> = token.chars().collect();
        for w in chars.windows(2) {
            if w[0].is_lowercase() && w[1].is_uppercase() {
                count += 1;
            }
        }
    }
    count
}

fn appendix_numbered(text: &str) -> bool {
    let t = text.trim();
    let mut it = t.chars();
    let first = it.next().unwrap_or(' ');
    let second = it.next().unwrap_or(' ');
    (first.is_ascii_uppercase() && second == ' ')
        || t.to_lowercase().starts_with("appendix")
        || t.to_lowercase().starts_with("приложение")
}

/// Sections that are always top level by meaning.
fn is_top_level_section_title(norm: &str) -> bool {
    const NAMES: &[&str] = &[
        "abstract",
        "references",
        "bibliography",
        "appendix",
        "literature cited",
        "аннотация",
        "литература",
        "список литературы",
        "список источников",
        "приложение",
    ];
    NAMES.iter().any(|n| norm == *n)
}

fn is_references_title(norm: &str) -> bool {
    const NAMES: &[&str] = &[
        "references",
        "bibliography",
        "литература",
        "список литературы",
        "список источников",
        "источники",
    ];
    NAMES.iter().any(|n| norm == *n)
}

fn doc_body_size(pages: &[PageRaw]) -> f64 {
    let mut counts: HashMap<i32, usize> = HashMap::new();
    for pg in pages {
        for l in &pg.lines {
            if l.size > 0.5 {
                *counts.entry((l.size * 2.0).round() as i32).or_default() += l.char_count.max(1);
            }
        }
    }
    counts
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)))
        .map(|(k, _)| k as f64 / 2.0)
        .unwrap_or(0.0)
}

fn detect_header_footer(pages: &[PageRaw]) -> HashMap<(i32, String), BlockKind> {
    let mut seen: HashMap<(Zone, String), Vec<i32>> = HashMap::new();
    for pg in pages {
        for l in &pg.lines {
            if l.zone != Zone::Middle && l.char_count >= 1 && l.char_count <= 140 {
                seen.entry((l.zone, l.norm_text.clone()))
                    .or_default()
                    .push(pg.index);
            }
        }
    }
    let mut out = HashMap::new();
    for ((zone, norm), mut list) in seen {
        list.sort_unstable();
        list.dedup();
        if list.len() >= 3 {
            let kind = if zone == Zone::Top {
                BlockKind::Header
            } else {
                BlockKind::Footer
            };
            for p in list {
                out.insert((p, norm.clone()), kind);
            }
        }
    }
    out
}

/// Document title: the largest unnumbered heading in the upper half of the
/// first page. The block is marked `is_title` and excluded from headings.
fn select_title(drafts: &mut [Vec<BlockDraft>], pages: &[PageRaw]) -> Option<String> {
    let page0 = drafts.first_mut()?;
    if page0.is_empty() {
        return None;
    }
    let _page_h = pages.first().map(|p| p.height).unwrap_or(792.0);
    let mut best: Option<usize> = None;
    let mut best_size = 0.0f64;
    for (i, d) in page0.iter().enumerate() {
        if d.kind != BlockKind::Heading || d.is_title {
            continue;
        }
        if d.numbered_depth.is_some() {
            continue;
        }
        let size = d.lines.iter().map(|l| l.size).fold(0.0, f64::max);
        if size > best_size {
            best_size = size;
            best = Some(i);
        }
    }
    let idx = best?;
    // Glue together adjacent heading lines (a long title wrapping).
    let mut parts: Vec<String> = Vec::new();
    let mut i = idx;
    while i < page0.len() {
        let d = &page0[i];
        if d.kind != BlockKind::Heading || d.numbered_depth.is_some() {
            break;
        }
        let size = d.lines.iter().map(|l| l.size).fold(0.0, f64::max);
        if (size - best_size).abs() > 0.6 && i != idx {
            break;
        }
        if i != idx && d.bbox.y - page0[i - 1].bbox.bottom() > best_size * 1.6 {
            break;
        }
        parts.push(text::join_block_text(&d.lines));
        i += 1;
    }
    if parts.is_empty() {
        return None;
    }
    page0[idx].is_title = true;
    for d in page0.iter_mut().take(i).skip(idx) {
        d.is_title = true;
    }
    let title = parts.join(" ");
    let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
    if title.chars().count() < 3 {
        return None;
    }
    Some(title)
}

type StyleKey = (i32, bool, bool, bool);

fn block_style_key(d: &BlockDraft) -> StyleKey {
    let l = d.lines.first();
    match l {
        Some(l) => (
            (l.size * 2.0).round() as i32,
            l.bold_ratio >= 0.55,
            l.italic_ratio >= 0.55,
            l.mono_ratio > 0.5,
        ),
        None => (0, false, false, false),
    }
}

fn assign_levels(
    drafts: &mut [Vec<BlockDraft>],
    pages: &[PageRaw],
    outline: &[OutlineItem],
    tagged: bool,
) {
    // Rank style clusters among all heading candidates of the document.
    let mut keys: Vec<StyleKey> = Vec::new();
    for pg in drafts.iter() {
        for d in pg.iter() {
            if d.kind == BlockKind::Heading && !d.is_title {
                keys.push(block_style_key(d));
            }
        }
    }
    keys.sort_unstable();
    keys.dedup();
    let mut ranked = keys.clone();
    ranked.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then(b.1.cmp(&a.1))
            .then(a.2.cmp(&b.2))
            .then(a.3.cmp(&b.3))
    });
    let mut level_of: HashMap<StyleKey, i32> = HashMap::new();
    for (i, k) in ranked.iter().enumerate() {
        level_of.insert(*k, ((i as i32) + 1).min(6));
    }

    let outline_flat = flatten_outline(outline, 0);
    for (pi, pg) in drafts.iter_mut().enumerate() {
        let title_on_page = pg.iter().any(|d| d.is_title);
        let heading_count = pg
            .iter()
            .filter(|d| d.kind == BlockKind::Heading && !d.is_title)
            .count();
        let mut tags: Vec<i32> = pages
            .get(pi)
            .map(|p| p.tag_headings.clone())
            .unwrap_or_default();
        if tagged && title_on_page && tags.len() == heading_count + 1 {
            tags.remove(0);
        }
        let use_tags = tagged && !tags.is_empty() && tags.len() == heading_count;
        let mut tag_i = 0usize;

        for d in pg.iter_mut() {
            if d.kind != BlockKind::Heading {
                d.level = 0;
                continue;
            }
            if d.is_title {
                d.level = 1;
                d.source = "heuristic".to_string();
                continue;
            }
            let key = block_style_key(d);
            let mut level = match d.numbered_depth {
                Some(depth) => depth.clamp(1, 6),
                None => *level_of.get(&key).unwrap_or(&1),
            };
            let mut source = "heuristic";
            if let (true, Some(tag)) = (use_tags, tags.get(tag_i)) {
                if d.numbered_depth.is_none() {
                    level = (*tag).clamp(1, 6);
                    source = "tagged";
                }
                tag_i += 1;
            }
            if d.numbered_depth.is_none() {
                let t = normalize_title(&text::join_block_text(&d.lines));
                if let Some((_, opage, odepth)) = outline_flat.iter().find(|(tt, _, _)| tt == &t) {
                    if *opage < 0 || *opage == pi as i32 {
                        level = (*odepth + 1).clamp(1, 6);
                        source = "outline";
                    }
                }
                // Abstract/References/Literature/Appendix are always top level.
                if is_top_level_section_title(&t) {
                    level = 1;
                }
            }
            d.level = level;
            d.source = source.to_string();
        }
    }
}

fn flatten_outline(items: &[OutlineItem], depth: i32) -> Vec<(String, i32, i32)> {
    let mut out = Vec::new();
    for it in items {
        out.push((normalize_title(&it.title), it.page, depth));
        out.extend(flatten_outline(&it.children, depth + 1));
    }
    out
}

fn normalize_title(s: &str) -> String {
    let mut out = String::new();
    let mut prev_space = false;
    for ch in s.trim().chars() {
        if ch.is_alphanumeric() {
            for lc in ch.to_lowercase() {
                out.push(lc);
            }
            prev_space = false;
        } else if ch.is_whitespace() {
            if !prev_space && !out.is_empty() {
                out.push(' ');
                prev_space = true;
            }
        }
    }
    out.trim().to_string()
}

fn build_outline_from_headings(headings: &[Heading]) -> Vec<OutlineItem> {
    fn build(
        headings: &[Heading],
        idx: &mut usize,
        doc_level: i32,
        depth: i32,
    ) -> Vec<OutlineItem> {
        let mut out = Vec::new();
        while *idx < headings.len() {
            let h = &headings[*idx];
            if h.level < doc_level {
                break;
            }
            *idx += 1;
            let mut node = OutlineItem {
                title: h.title.clone(),
                page: h.page,
                level: depth,
                children: Vec::new(),
            };
            if *idx < headings.len() && headings[*idx].level > h.level {
                let child_level = headings[*idx].level;
                node.children = build(headings, idx, child_level, depth + 1);
            }
            out.push(node);
        }
        out
    }
    let mut idx = 0;
    let start = headings.first().map(|h| h.level).unwrap_or(1);
    build(headings, &mut idx, start, 0)
}

fn confidence_of(d: &BlockDraft) -> f64 {
    let v = if d.kind == BlockKind::Heading {
        if d.is_title {
            1.0
        } else {
            d.heading_score.max(0.6)
        }
    } else {
        match d.kind {
            BlockKind::Body => 0.9,
            BlockKind::List => 0.85,
            BlockKind::Caption => 0.88,
            BlockKind::Code => 0.9,
            BlockKind::Formula => 0.8,
            BlockKind::Header | BlockKind::Footer => 0.95,
            BlockKind::Reference => 0.8,
            BlockKind::Quote => 0.7,
            BlockKind::Table => 0.7,
            BlockKind::Heading => 0.8,
        }
    };
    (v * 100.0).round() / 100.0
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

pub fn search(
    p: &Pdfium,
    doc: FPDF_DOCUMENT,
    query: &str,
    max_hits: usize,
) -> Result<SearchResult, String> {
    let q: Vec<u16> = query.encode_utf16().collect();
    let mut hits = Vec::new();
    if q.is_empty() {
        return Ok(SearchResult {
            query: query.to_string(),
            hits,
        });
    }
    let mut qn = q.clone();
    qn.push(0);
    let page_count = unsafe { (p.FPDF_GetPageCount)(doc) };
    for i in 0..page_count {
        if hits.len() >= max_hits {
            break;
        }
        let page = unsafe { (p.FPDF_LoadPage)(doc, i) };
        if page.is_null() {
            continue;
        }
        let geo = text::page_geometry(p, page);
        let tp = unsafe { (p.FPDFText_LoadPage)(page) };
        if tp.is_null() {
            unsafe { (p.FPDF_ClosePage)(page) };
            continue;
        }
        let total = unsafe { (p.FPDFText_CountChars)(tp) };
        unsafe {
            // flags = 0 → case-insensitive (PDFium does not match case).
            let find = (p.FPDFText_FindStart)(tp, qn.as_ptr(), 0, 0);
            if !find.is_null() {
                let mut guard = 0;
                while (p.FPDFText_FindNext)(find) != 0 && hits.len() < max_hits && guard < 2000 {
                    guard += 1;
                    let start = (p.FPDFText_GetSchResultIndex)(find);
                    let count = (p.FPDFText_GetSchCount)(find);
                    if start < 0 || count <= 0 {
                        continue;
                    }
                    let rects = match_rects(p, tp, start, count, &geo);
                    let snippet = match_snippet(p, tp, start, count, total);
                    hits.push(SearchHit {
                        page: i,
                        rects,
                        snippet,
                    });
                }
                (p.FPDFText_FindClose)(find);
            }
            (p.FPDFText_ClosePage)(tp);
            (p.FPDF_ClosePage)(page);
        }
    }
    Ok(SearchResult {
        query: query.to_string(),
        hits,
    })
}

unsafe fn match_rects(
    p: &Pdfium,
    tp: FPDF_TEXTPAGE,
    start: i32,
    count: i32,
    geo: &text::PageGeometry,
) -> Vec<Rect> {
    let mut out = Vec::new();
    let n = (p.FPDFText_CountRects)(tp, start, count);
    for j in 0..n.max(0).min(400) {
        let mut left = 0.0f64;
        let mut top = 0.0f64;
        let mut right = 0.0f64;
        let mut bottom = 0.0f64;
        if (p.FPDFText_GetRect)(tp, j, &mut left, &mut top, &mut right, &mut bottom) == 0 {
            continue;
        }
        let rect_un = Rect::from_ltrb(
            left - geo.bx0,
            geo.by_top - top,
            right - geo.bx0,
            geo.by_top - bottom,
        );
        out.push(text::rotate_rect(rect_un, geo.rotation, geo.raw_w, geo.raw_h));
    }
    out
}

unsafe fn match_snippet(
    p: &Pdfium,
    tp: FPDF_TEXTPAGE,
    start: i32,
    count: i32,
    total: i32,
) -> String {
    let ctx = 40;
    let from = (start - ctx).max(0);
    let to = (start + count + ctx).min(total.max(0));
    let n = (to - from).max(0);
    if n <= 0 {
        return String::new();
    }
    let mut buf = vec![0u16; (n as usize) + 1];
    let written = (p.FPDFText_GetText)(tp, from, n, buf.as_mut_ptr());
    let used = (written.max(0) as usize).saturating_sub(1).min(buf.len());
    let s = String::from_utf16_lossy(&buf[..used]);
    let mut out = String::new();
    for ch in s.chars() {
        if ch.is_whitespace() {
            if !out.ends_with(' ') {
                out.push(' ');
            }
        } else {
            out.push(ch);
        }
    }
    let body = out.trim();
    let mut res = String::new();
    if from > 0 {
        res.push('…');
    }
    res.push_str(body);
    if to < total {
        res.push('…');
    }
    res
}
