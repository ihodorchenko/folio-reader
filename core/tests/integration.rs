//! Integration tests for the core on real PDFs from `samples/`.
//!
//! They cover the C ABI, the JSON contract, the structure, rendering and error handling.
//! If the samples are missing, the tests that need them are reported as skipped.

use pdfcore::api::Document;
use pdfcore::json_types::BlockKind;
use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};

fn samples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../samples")
}

fn sample(name: &str) -> PathBuf {
    samples().join(name)
}

fn has(name: &str) -> bool {
    sample(name).is_file()
}

fn heading_by<'a>(
    st: &'a pdfcore::json_types::DocumentStructure,
    needle: &str,
) -> Option<&'a pdfcore::json_types::Heading> {
    st.headings.iter().find(|h| {
        h.title
            .to_lowercase()
            .contains(&needle.to_lowercase())
    })
}

#[test]
fn attention_structure() {
    if !has("attention.pdf") {
        eprintln!("samples/attention.pdf is missing — skipping");
        return;
    }
    let doc = Document::open(sample("attention.pdf").to_str().unwrap()).expect("open attention");
    assert_eq!(doc.page_count().unwrap(), 15);

    let st = doc.structure().unwrap();
    assert_eq!(st.page_count, 15);
    assert_eq!(st.schema, 1);
    assert!(!st.tagged);
    let title = st.title.clone().unwrap_or_default();
    assert!(
        title.to_lowercase().contains("attention"),
        "title = {:?}",
        title
    );

    assert!(st.headings.len() >= 10, "headings: {}", st.headings.len());
    assert!(st.headings.len() <= 30, "too many headings: {}", st.headings.len());
    for expected in ["Introduction", "Background", "Model Architecture", "Conclusion"] {
        assert!(
            heading_by(&st, expected).is_some(),
            "missing heading {expected}: {:?}",
            st.headings.iter().map(|h| &h.title).collect::<Vec<_>>()
        );
    }
    assert!(heading_by(&st, "Encoder and Decoder Stacks").is_some());
    assert_eq!(heading_by(&st, "Introduction").unwrap().level, 1);
    assert_eq!(heading_by(&st, "Encoder and Decoder Stacks").unwrap().level, 2);
    assert_eq!(heading_by(&st, "Abstract").unwrap().level, 1);
    assert_eq!(heading_by(&st, "References").unwrap().level, 1);
    assert_eq!(
        heading_by(&st, "Scaled Dot-Product Attention").unwrap().level,
        3
    );

    // Headers/footers and junk must not become headings.
    let titles: Vec<String> = st.headings.iter().map(|h| h.title.to_lowercase()).collect();
    for bad in [
        "provided proper attribution",
        "arxiv:",
        "input-input",
        "стр.",
        "страница",
    ] {
        assert!(
            !titles.iter().any(|t| t.contains(bad)),
            "header/footer or junk leaked into headings: {bad}"
        );
    }
    // There must be no duplicate headings.
    let mut uniq = std::collections::HashSet::new();
    for t in &titles {
        assert!(uniq.insert(t.clone()), "duplicate heading: {t}");
    }

    // All bboxes are within the page bounds.
    for h in &st.headings {
        let (w, ph) = doc.page_size(h.page).unwrap();
        assert!(h.bbox.x >= -2.0 && h.bbox.x <= w + 2.0, "bbox.x {}", h.bbox.x);
        assert!(h.bbox.y >= -2.0 && h.bbox.y <= ph + 2.0, "bbox.y {}", h.bbox.y);
        assert!(h.bbox.w > 0.0 && h.bbox.h > 0.0);
    }
}

#[test]
fn attention_page_layout_json() {
    if !has("attention.pdf") {
        return;
    }
    let doc = Document::open(sample("attention.pdf").to_str().unwrap()).unwrap();
    let json = doc.page_layout_json(0).unwrap();
    let v: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
    assert_eq!(v["schema"], 1);
    assert_eq!(v["index"], 0);
    assert_eq!(v["rotation"], 0);
    assert!((v["width"].as_f64().unwrap() - 612.0).abs() < 1.0);
    assert!((v["height"].as_f64().unwrap() - 792.0).abs() < 1.0);
    let body = v["bodyFontSize"].as_f64().unwrap();
    assert!((8.0..=12.0).contains(&body), "bodyFontSize {body}");

    let blocks = v["blocks"].as_array().unwrap();
    assert!(!blocks.is_empty());
    let mut words = 0usize;
    let mut heading_found = false;
    for b in blocks {
        if b["kind"] == "heading" {
            heading_found = true;
        }
        assert!(b["bbox"]["w"].as_f64().unwrap() >= 0.0);
        for l in b["lines"].as_array().unwrap() {
            words += l["words"].as_array().unwrap().len();
        }
    }
    assert!(words >= 200, "words: {words}");
    assert!(heading_found);
    // The JSON must not contain NaN/Infinity — serde_json would not emit them anyway,
    // but double-check the string as well.
    assert!(!json.contains("NaN") && !json.contains("Infinity"));
}

#[test]
fn attention_blocks_are_sane() {
    if !has("attention.pdf") {
        return;
    }
    let doc = Document::open(sample("attention.pdf").to_str().unwrap()).unwrap();
    let layout = doc.page_layout(0).unwrap();
    let kinds: std::collections::HashMap<BlockKind, usize> =
        layout.blocks.iter().fold(Default::default(), |mut m, b| {
            *m.entry(b.kind).or_default() += 1;
            m
        });
    assert!(kinds.get(&BlockKind::Body).copied().unwrap_or(0) > 0);
    assert!(kinds.get(&BlockKind::Heading).copied().unwrap_or(0) >= 1);
    // Single footnote markers must not become separate blocks.
    assert_eq!(kinds.get(&BlockKind::Footer).copied().unwrap_or(0), 0);
    for b in &layout.blocks {
        assert!(!b.id.is_empty());
        assert!(!b.text.trim().is_empty(), "empty block text {}", b.id);
        for l in &b.lines {
            assert!(!l.words.is_empty());
        }
    }
}

#[test]
fn sample_ru_structure_flipped_document() {
    if !has("sample-ru.pdf") {
        return;
    }
    let doc = Document::open(sample("sample-ru.pdf").to_str().unwrap()).unwrap();
    let st = doc.structure().unwrap();
    assert_eq!(st.page_count, 3);
    let title = st.title.clone().unwrap_or_default();
    assert_eq!(title, "Структура PDF-документа");
    assert!(st.headings.len() >= 8, "headings: {}", st.headings.len());

    let vved = heading_by(&st, "Введение").expect("1. Введение");
    assert_eq!(vved.level, 1);
    // The coordinates are normalized: the heading is at the top edge.
    assert!(vved.bbox.y < 300.0, "y={}", vved.bbox.y);
    let tip = heading_by(&st, "Типографические признаки").expect("1.1");
    assert_eq!(tip.level, 2);
    assert!(heading_by(&st, "Сильное нажатие").is_some());
    assert!(heading_by(&st, "Литература").is_some());

    // Headers/footers are not headings, but they are classified as header in the layout.
    let titles: Vec<String> = st.headings.iter().map(|h| h.title.clone()).collect();
    assert!(!titles.iter().any(|t| t.contains("демонстрационный документ")));
    assert!(!titles.iter().any(|t| t.contains("из 3")));
    let layout = doc.page_layout(0).unwrap();
    let header = layout
        .blocks
        .iter()
        .find(|b| b.text.contains("демонстрационный документ"))
        .expect("header block");
    assert_eq!(header.kind, BlockKind::Header);
    let footer = layout
        .blocks
        .iter()
        .find(|b| b.text.contains("Стр. 1 из 3"))
        .expect("page number");
    assert_eq!(footer.kind, BlockKind::Header);

    // Reading order: title → 1. Введение → 1.1 → 1.2.
    let mut y = f64::NEG_INFINITY;
    for h in &st.headings {
        assert!(
            h.bbox.y > y - 1.0 || h.page > 0,
            "headings are not in reading order: {:?}",
            st.headings.iter().map(|h| (&h.title, h.bbox.y)).collect::<Vec<_>>()
        );
        y = h.bbox.y;
    }
}

#[test]
fn no_text_pdf_does_not_panic() {
    if !has("no-text.pdf") {
        return;
    }
    let doc = Document::open(sample("no-text.pdf").to_str().unwrap()).unwrap();
    let st = doc.structure().unwrap();
    assert_eq!(st.headings.len(), 0);
    let layout = doc.page_layout(0).unwrap();
    let words: usize = layout
        .blocks
        .iter()
        .flat_map(|b| b.lines.iter())
        .map(|l| l.words.len())
        .sum();
    assert_eq!(words, 0);
    let rendered = doc.render_page(0, 1.0).unwrap();
    assert!(rendered.width > 100 && rendered.height > 100);
    assert_eq!(rendered.bgra.len(), rendered.width as usize * rendered.height as usize * 4);
    assert!(rendered.bgra.chunks_exact(4).all(|px| px[3] == 255));
}

#[test]
fn bad_inputs_return_errors_not_panics() {
    let missing = Document::open("/tmp/definitely-not-here-folio.pdf");
    assert!(missing.is_err());

    let dir = std::env::temp_dir().join("folio_pdfcore_bad_input_test");
    std::fs::create_dir_all(&dir).unwrap();
    let garbage = dir.join("garbage.pdf");
    std::fs::write(&garbage, b"this is definitely not a pdf file").unwrap();
    let bad = Document::open(garbage.to_str().unwrap());
    assert!(bad.is_err(), "a corrupt file must return an error");
    // The file is not kept open: it can be deleted.
    std::fs::remove_file(&garbage).unwrap();

    // A non-PDF from the repository (a text file).
    let txt = dir.join("note.txt");
    std::fs::write(&txt, "hello").unwrap();
    assert!(Document::open(txt.to_str().unwrap()).is_err());
    std::fs::remove_file(&txt).ok();
}

#[test]
fn render_orientation_matches_text_coordinates() {
    if !has("attention.pdf") {
        return;
    }
    let doc = Document::open(sample("attention.pdf").to_str().unwrap()).unwrap();
    let rendered = doc.render_page(0, 1.0).unwrap();
    let (w, h) = (rendered.width as usize, rendered.height as usize);
    assert_eq!((w, h), (612, 792));

    // The top 40 rows are page margins and almost white; the title (bbox y≈150)
    // must produce a noticeable amount of dark pixels.
    let dark = |y0: usize, y1: usize| -> usize {
        let mut n = 0;
        for y in y0..y1.min(h) {
            for x in 0..w {
                let p = y * w * 4 + x * 4;
                if rendered.bgra[p] < 120 && rendered.bgra[p + 1] < 120 && rendered.bgra[p + 2] < 120 {
                    n += 1;
                }
            }
        }
        n
    };
    let top_margin = dark(0, 40);
    let title_band = dark(150, 170);
    assert!(
        top_margin < 200,
        "the top row is not white → is the raster flipped? dark={top_margin}"
    );
    assert!(title_band > 300, "no text in the title band (flipped raster?)");
    // The bottom area of the page (conference footer) also contains text.
    assert!(dark(700, 792) > 0, "the bottom of the page is empty (raster/coordinates do not match)");
}

#[test]
fn search_finds_latin_and_cyrillic() {
    if has("attention.pdf") {
        let doc = Document::open(sample("attention.pdf").to_str().unwrap()).unwrap();
        let res = doc.search("attention").unwrap();
        assert!(!res.hits.is_empty());
        assert!(res.hits.iter().all(|h| h.page >= 0 && h.page < 15));
        assert!(res
            .hits
            .iter()
            .all(|h| h.rects.iter().all(|r| r.w > 0.0 && r.h > 0.0)));
        assert!(res.hits.iter().any(|h| h.snippet.to_lowercase().contains("attention")));
    }
    if has("sample-ru.pdf") {
        let doc = Document::open(sample("sample-ru.pdf").to_str().unwrap()).unwrap();
        let res = doc.search("словарь").unwrap();
        assert!(!res.hits.is_empty(), "Cyrillic search does not work");
    }
}

#[test]
fn c_abi_roundtrip() {
    if !has("attention.pdf") {
        return;
    }
    let path = sample("attention.pdf");
    let cpath = CString::new(path.to_str().unwrap()).unwrap();
    unsafe {
        let doc = pdfcore::pc_open(cpath.as_ptr());
        assert!(!doc.is_null(), "pc_open returned NULL");
        assert_eq!(pdfcore::pc_page_count(doc), 15);
        assert!((pdfcore::pc_page_width(doc, 0) - 612.0).abs() < 1.0);
        assert!((pdfcore::pc_page_height(doc, 0) - 792.0).abs() < 1.0);

        let json = pdfcore::pc_page_layout_json(doc, 0);
        assert!(!json.is_null());
        let text = CStr::from_ptr(json).to_str().unwrap().to_string();
        pdfcore::pc_free_json(json);
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["schema"], 1);

        let structure = pdfcore::pc_document_structure_json(doc);
        assert!(!structure.is_null());
        let stext = CStr::from_ptr(structure).to_str().unwrap().to_string();
        pdfcore::pc_free_json(structure);
        let sv: serde_json::Value = serde_json::from_str(&stext).unwrap();
        assert!(sv["headings"].as_array().unwrap().len() >= 10);

        let query = CString::new("attention").unwrap();
        let search = pdfcore::pc_search_json(doc, query.as_ptr());
        assert!(!search.is_null());
        pdfcore::pc_free_json(search);

        let mut w = 0i32;
        let mut h = 0i32;
        let mut buf: *mut u8 = std::ptr::null_mut();
        let rc = pdfcore::pc_render_page(doc, 0, 1.0, &mut w, &mut h, &mut buf);
        assert_eq!(rc, 0);
        assert_eq!((w, h), (612, 792));
        assert!(!buf.is_null());
        let slice = std::slice::from_raw_parts(buf, (w * h * 4) as usize);
        assert!(slice.chunks_exact(4).all(|px| px[3] == 255));
        pdfcore::pc_free_buffer(buf as *mut std::ffi::c_void);

        pdfcore::pc_close(doc);

        // Errors: NULL and a nonexistent file.
        assert!(pdfcore::pc_open(std::ptr::null()).is_null());
        let err = pdfcore::pc_last_error();
        assert!(!err.is_null());
        assert!(!CStr::from_ptr(err).to_bytes().is_empty());
        let missing = CString::new("/tmp/definitely-not-here-folio.pdf").unwrap();
        assert!(pdfcore::pc_open(missing.as_ptr()).is_null());
        // Functions required by the contract even though they are unused here.
        let v = pdfcore::pc_version();
        assert!(!v.is_null());
        assert!(CStr::from_ptr(v).to_string_lossy().contains("pdfcore"));
    }
}

#[test]
fn c_abi_null_safety() {
    unsafe {
        assert_eq!(pdfcore::pc_page_count(std::ptr::null()), -1);
        assert_eq!(pdfcore::pc_page_width(std::ptr::null(), 0), 0.0);
        assert_eq!(pdfcore::pc_page_height(std::ptr::null(), 0), 0.0);
        assert!(pdfcore::pc_page_layout_json(std::ptr::null(), 0).is_null());
        assert!(pdfcore::pc_document_structure_json(std::ptr::null()).is_null());
        assert!(pdfcore::pc_search_json(std::ptr::null(), std::ptr::null()).is_null());
        pdfcore::pc_close(std::ptr::null_mut());
        pdfcore::pc_free_json(std::ptr::null_mut());
        pdfcore::pc_free_buffer(std::ptr::null_mut());
    }
}

#[test]
fn json_is_serializable_and_finite() {
    if !has("sample-ru.pdf") {
        return;
    }
    let doc = Document::open(sample("sample-ru.pdf").to_str().unwrap()).unwrap();
    let st = doc.structure().unwrap();
    let json = serde_json::to_string(&st).unwrap();
    assert!(!json.contains("NaN") && !json.contains("Infinity"));
    // Every page serializes and parses back.
    for i in 0..st.page_count {
        let text = doc.page_layout_json(i).unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["index"], i);
    }
}

/// Path to the pc-cli binary for the CLI smoke test (if it is built).
#[allow(dead_code)]
fn pc_cli() -> Option<PathBuf> {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/debug/pc-cli");
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

#[test]
fn concurrent_access_is_thread_safe() {
    if !has("attention.pdf") {
        return;
    }
    let doc = std::sync::Arc::new(Document::open(sample("attention.pdf").to_str().unwrap()).unwrap());
    let mut handles = Vec::new();
    for i in 0..4i32 {
        let doc = doc.clone();
        handles.push(std::thread::spawn(move || {
            for j in 0..4i32 {
                let page = (i * 3 + j) % 15;
                let layout = doc.page_layout_json(page).unwrap();
                assert!(layout.contains("\"schema\":1"));
                let st = doc.structure().unwrap();
                assert!(st.headings.len() >= 10);
                let hits = doc.search("attention").unwrap();
                assert!(!hits.hits.is_empty());
                let rendered = doc.render_page(page, 0.5).unwrap();
                assert_eq!(
                    rendered.bgra.len(),
                    rendered.width as usize * rendered.height as usize * 4
                );
            }
        }));
    }
    for h in handles {
        h.join().expect("thread panicked (PDFium not serialized?)");
    }
}
