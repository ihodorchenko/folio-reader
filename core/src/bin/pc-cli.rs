//! pc-cli — debugging CLI for the core (CONTRACT §9 acceptance).
//!
//! Examples:
//!   pc-cli info samples/attention.pdf
//!   pc-cli structure samples/attention.pdf
//!   pc-cli text samples/attention.pdf --page 0
//!   pc-cli blocks samples/attention.pdf --page 0
//!   pc-cli render samples/attention.pdf --page 0 --scale 2 --out /tmp/page.ppm
//!   pc-cli bench samples/attention.pdf
//!   pc-cli search samples/attention.pdf attention
//!   pc-cli fonts samples/attention.pdf

use pdfcore::api::Document;
use pdfcore::json_types::*;
use std::collections::HashMap;
use std::path::Path;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        std::process::exit(1);
    }
    let result = match args[0].as_str() {
        "info" => cmd_info(&args[1..]),
        "text" => cmd_text(&args[1..]),
        "structure" => cmd_structure(&args[1..]),
        "blocks" => cmd_blocks(&args[1..]),
        "render" => cmd_render(&args[1..]),
        "bench" => cmd_bench(&args[1..]),
        "search" => cmd_search(&args[1..]),
        "chars" => cmd_chars(&args[1..]),
        "fonts" => cmd_fonts(&args[1..]),
        "rawchars" => cmd_rawchars(&args[1..]),
        "version" => {
            println!("{}", version_string());
            Ok(())
        }
        other => Err(format!("unknown command \"{}\" (see pc-cli with no arguments)", other)),
    };
    if let Err(e) = result {
        eprintln!("pc-cli: {}", e);
        std::process::exit(2);
    }
}

fn usage() {
    println!(
        "pc-cli {} — pdfcore core debugging\n\
         commands:\n  \
         info <pdf>\n  \
         structure <pdf> [--json]\n  \
         text <pdf> [--page N] [--pretty]\n  \
         blocks <pdf> --page N\n  \
         render <pdf> --page N [--scale 2] --out file.ppm\n  \
         bench <pdf>\n  \
         search <pdf> <query>\n  \
         chars <pdf> [--page N] [--limit K]\n  \
         fonts <pdf>\n  \
         version",
        env!("CARGO_PKG_VERSION")
    );
}

fn version_string() -> String {
    unsafe {
        let ptr = pdfcore::pc_version();
        if ptr.is_null() {
            return format!("pdfcore {}", env!("CARGO_PKG_VERSION"));
        }
        std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

#[derive(Default)]
struct Opts {
    path: String,
    page: Option<i32>,
    scale: f64,
    out: Option<String>,
    pretty: bool,
    json: bool,
    limit: usize,
}

fn parse_opts(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts {
        scale: 1.0,
        limit: 0,
        ..Default::default()
    };
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        match a.as_str() {
            "--page" | "-p" => {
                i += 1;
                let v = args.get(i).ok_or("--page requires a number")?;
                o.page = Some(v.parse().map_err(|_| format!("invalid page: {}", v))?);
            }
            "--scale" | "-s" => {
                i += 1;
                let v = args.get(i).ok_or("--scale requires a number")?;
                o.scale = v.parse().map_err(|_| format!("invalid scale: {}", v))?;
            }
            "--out" | "-o" => {
                i += 1;
                o.out = Some(args.get(i).ok_or("--out requires a path")?.clone());
            }
            "--pretty" => o.pretty = true,
            "--json" => o.json = true,
            "--limit" => {
                i += 1;
                let v = args.get(i).ok_or("--limit requires a number")?;
                o.limit = v.parse().map_err(|_| format!("invalid --limit: {}", v))?;
            }
            other if other.starts_with('-') => {
                return Err(format!("unknown flag: {}", other));
            }
            other => {
                if o.path.is_empty() {
                    o.path = resolve_path(other);
                } else {
                    return Err(format!("unexpected argument: {}", other));
                }
            }
        }
        i += 1;
    }
    if o.path.is_empty() {
        return Err("a PDF path is required".to_string());
    }
    Ok(o)
}

/// Resolve the PDF path: as given, then relative to the repository (samples/).
fn resolve_path(p: &str) -> String {
    if Path::new(p).exists() {
        return p.to_string();
    }
    let base = Path::new(p)
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default();
    let candidates = [
        format!("../{}", p),
        format!("../../{}", p),
        format!("samples/{}", base),
        format!("../samples/{}", base),
        format!("../../samples/{}", base),
    ];
    for c in candidates {
        if Path::new(&c).exists() {
            return c;
        }
    }
    p.to_string()
}

fn open(path: &str) -> Result<Document, String> {
    Document::open(path)
}

// ---------------------------------------------------------------------------

fn cmd_info(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let t0 = Instant::now();
    let doc = open(&o.path)?;
    let open_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let t1 = Instant::now();
    let st = doc.structure()?;
    let struct_ms = t1.elapsed().as_secs_f64() * 1000.0;
    println!("path: {}", o.path);
    println!("pages: {}", st.page_count);
    println!("title: {}", st.title.as_deref().unwrap_or("(none)"));
    println!("tagged: {}", st.tagged);
    println!("bodyFontSize: {}", st.metrics.body_font_size);
    println!("sizeClusters: {:?}", st.metrics.size_clusters);
    println!("outline items: {}", count_outline(&st.outline));
    println!("headings: {}", st.headings.len());
    if let Ok(Some((w, h))) = first_page_size(&doc) {
        println!("page0 size: {} x {} pt", w, h);
    }
    println!("open: {:.1} ms, structure: {:.1} ms", open_ms, struct_ms);
    Ok(())
}

fn first_page_size(doc: &Document) -> Result<Option<(f64, f64)>, String> {
    if doc.page_count()? > 0 {
        Ok(Some(doc.page_size(0)?))
    } else {
        Ok(None)
    }
}

fn count_outline(items: &[OutlineItem]) -> usize {
    items
        .iter()
        .map(|i| 1 + count_outline(&i.children))
        .sum()
}

fn cmd_text(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let doc = open(&o.path)?;
    let page = o.page.unwrap_or(0);
    let json = doc.page_layout_json(page)?;
    if o.pretty {
        match serde_json::from_str::<serde_json::Value>(&json) {
            Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap_or(json)),
            Err(_) => println!("{}", json),
        }
    } else {
        println!("{}", json);
    }
    Ok(())
}

fn cmd_structure(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let doc = open(&o.path)?;
    let st = doc.structure()?;
    if o.json {
        println!("{}", doc.document_structure_json()?);
        return Ok(());
    }
    // Map block id → font (for printing next to headings).
    let mut fonts: HashMap<String, Font> = HashMap::new();
    for i in 0..st.page_count {
        if let Ok(layout) = doc.page_layout(i) {
            for b in layout.blocks {
                fonts.insert(b.id, b.font);
            }
        }
    }
    println!("path: {}", o.path);
    println!("title: {}", st.title.as_deref().unwrap_or("(none)"));
    println!("pages: {}", st.page_count);
    println!("tagged: {}", st.tagged);
    println!("bodyFontSize: {}", st.metrics.body_font_size);
    println!("sizeClusters: {:?}", st.metrics.size_clusters);
    if !st.outline.is_empty() {
        println!("outline:");
        print_outline(&st.outline, 1);
    } else {
        println!("outline: (empty, built from headings)");
    }
    println!("structure ({} headings):", st.headings.len());
    // st.headings are already in document order (and account for flipped PDFs).
    let headings = &st.headings;
    for h in headings {
        let indent = "  ".repeat((h.level.max(1) as usize).min(6));
        let font = fonts
            .get(&h.id)
            .map(|f| {
                format!(
                    "{} {:.1}{}{}",
                    if f.name.is_empty() { "(?)" } else { &f.name },
                    f.size,
                    if f.bold { " bold" } else { "" },
                    if f.italic { " italic" } else { "" }
                )
            })
            .unwrap_or_else(|| "(?)".to_string());
        println!(
            "{}{} L{} p{} bbox=({:.1},{:.1} {:.1}x{:.1}) {} conf={:.2} [{}]  \"{}\"",
            indent,
            level_tag(h.level),
            h.level,
            h.page,
            h.bbox.x,
            h.bbox.y,
            h.bbox.w,
            h.bbox.h,
            font,
            h.confidence,
            h.source,
            h.title.replace(['\n', '\r'], " ")
        );
    }
    Ok(())
}

fn level_tag(level: i32) -> &'static str {
    match level {
        1 => "L1",
        2 => "L2",
        3 => "L3",
        4 => "L4",
        5 => "L5",
        _ => "L?",
    }
}

fn print_outline(items: &[OutlineItem], depth: usize) {
    for it in items {
        let indent = "  ".repeat(depth);
        println!("{}- p{} [depth {}] \"{}\"", indent, it.page, it.level, it.title);
        print_outline(&it.children, depth + 1);
    }
}

fn cmd_blocks(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let doc = open(&o.path)?;
    let page = o.page.unwrap_or(0);
    let layout = doc.page_layout(page)?;
    println!(
        "page {}: {}x{} pt, rotation {}, bodyFontSize {}, {} blocks",
        layout.index,
        layout.width,
        layout.height,
        layout.rotation,
        layout.body_font_size,
        layout.blocks.len()
    );
    for b in &layout.blocks {
        let preview: String = b.text.chars().take(90).collect();
        println!(
            "  {} {:<9} L{} ({:.1},{:.1} {:.1}x{:.1}) {} {:.1}{}{} conf={:.2} lines={}  \"{}\"{}",
            b.id,
            b.kind.as_str(),
            b.level,
            b.bbox.x,
            b.bbox.y,
            b.bbox.w,
            b.bbox.h,
            if b.font.name.is_empty() { "(?)" } else { &b.font.name },
            b.font.size,
            if b.font.bold { " bold" } else { "" },
            if b.font.monospace { " mono" } else { "" },
            b.confidence,
            b.lines.len(),
            preview.replace(['\n', '\r'], " "),
            if b.text.chars().count() > 90 { "…" } else { "" }
        );
    }
    Ok(())
}

fn cmd_chars(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let doc = open(&o.path)?;
    let page = o.page.unwrap_or(0);
    let layout = doc.page_layout(page)?;
    println!(
        "page {}: {} lines, bodyFontSize {}",
        layout.index,
        layout.blocks.iter().map(|b| b.lines.len()).sum::<usize>(),
        layout.body_font_size
    );
    let mut n = 0usize;
    for b in &layout.blocks {
        for l in &b.lines {
            let w = l.words.first();
            let fontinfo = w
                .map(|w| {
                    format!(
                        "{} {:.1}{}{}",
                        w.font,
                        w.size,
                        if w.bold { " bold" } else { "" },
                        if w.italic { " italic" } else { "" }
                    )
                })
                .unwrap_or_default();
            println!(
                "  [{}] y={:.1} x={:.1} w={:.1} base={:.1} {} | {}",
                b.kind.as_str(),
                l.bbox.y,
                l.bbox.x,
                l.bbox.w,
                l.baseline_y,
                fontinfo,
                l.text
            );
            n += 1;
            if o.limit > 0 && n >= o.limit {
                return Ok(());
            }
        }
    }
    Ok(())
}

fn cmd_rawchars(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let doc = open(&o.path)?;
    let page = o.page.unwrap_or(0);
    let chars = doc.raw_page_chars(page)?;
    let mut shown = 0usize;
    for (i, c) in chars.iter().enumerate() {
        let ch = if c.ws { "␠".to_string() } else { c.ch.to_string() };
        println!(
            "{:>5} {:>6} x={:8.2} y={:8.2} w={:6.2} h={:6.2} size={:5.2} m={:5.2} base={:7.2} {} {} gen={} | '{}'",
            i,
            format!("U+{:04X}", c.ch as u32),
            c.bbox.x,
            c.bbox.y,
            c.bbox.w,
            c.bbox.h,
            c.size,
            c.matrix_scale,
            c.baseline,
            if c.bold { "B" } else { "-" },
            if c.italic { "I" } else { "-" },
            c.generated,
            ch
        );
        shown += 1;
        if o.limit > 0 && shown >= o.limit {
            break;
        }
    }
    Ok(())
}

fn cmd_fonts(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let doc = open(&o.path)?;
    let st = doc.structure()?;
    let mut counts: HashMap<(String, i32, bool, bool), usize> = HashMap::new();
    for i in 0..st.page_count {
        let layout = doc.page_layout(i)?;
        for b in &layout.blocks {
            for l in &b.lines {
                for w in &l.words {
                    let key = (
                        w.font.clone(),
                        (w.size * 10.0).round() as i32,
                        w.bold,
                        w.italic,
                    );
                    *counts.entry(key).or_default() += w.text.chars().count();
                }
            }
        }
    }
    let mut v: Vec<_> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1));
    for ((name, size10, bold, italic), n) in v {
        println!(
            "{:>6}  {:<42} {:>5.1} {}{}",
            n,
            if name.is_empty() { "(?)" } else { &name },
            size10 as f64 / 10.0,
            if bold { "bold" } else { "" },
            if italic { " italic" } else { "" }
        );
    }
    Ok(())
}

fn cmd_render(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let out = o.out.clone().ok_or("--out file.ppm is required")?;
    let doc = open(&o.path)?;
    let page = o.page.unwrap_or(0);
    let t0 = Instant::now();
    let rendered = doc.render_page(page, o.scale)?;
    let ms = t0.elapsed().as_secs_f64() * 1000.0;
    let mut ppm = Vec::with_capacity(rendered.bgra.len() / 4 * 3 + 32);
    ppm.extend_from_slice(format!("P6\n{} {}\n255\n", rendered.width, rendered.height).as_bytes());
    for px in rendered.bgra.chunks_exact(4) {
        ppm.extend_from_slice(&[px[2], px[1], px[0]]);
    }
    std::fs::write(&out, &ppm).map_err(|e| format!("failed to write {}: {}", out, e))?;
    println!(
        "rendered page {} at scale {} → {}x{} px, {:.1} ms, {} bytes → {}",
        page,
        o.scale,
        rendered.width,
        rendered.height,
        ms,
        ppm.len(),
        out
    );
    if !out.ends_with(".ppm") {
        eprintln!("note: the file format is PPM (P6) regardless of the extension; convert it with sips");
    }
    Ok(())
}

fn cmd_search(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    if args.is_empty() {
        return Err("a query is required: pc-cli search <pdf> <query>".to_string());
    }
    let query = args.last().cloned().unwrap_or_default();
    let doc = open(&o.path)?;
    let t0 = Instant::now();
    let json = doc.search_json(&query)?;
    let ms = t0.elapsed().as_secs_f64() * 1000.0;
    println!("{}", json);
    eprintln!("search: {:.1} ms", ms);
    Ok(())
}

fn cmd_bench(args: &[String]) -> Result<(), String> {
    let o = parse_opts(args)?;
    let t0 = Instant::now();
    let doc = open(&o.path)?;
    let open_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let pages = doc.page_count()?;

    let t1 = Instant::now();
    let st = doc.structure()?;
    let struct_ms = t1.elapsed().as_secs_f64() * 1000.0;

    let t2 = Instant::now();
    let _ = doc.structure()?;
    let struct_cached_ms = t2.elapsed().as_secs_f64() * 1000.0;

    let t3 = Instant::now();
    for i in 0..pages {
        let _ = doc.page_layout_json(i)?;
    }
    let layouts_ms = t3.elapsed().as_secs_f64() * 1000.0;

    let t4 = Instant::now();
    let _ = doc.render_page(0, 2.0)?;
    let render_ms = t4.elapsed().as_secs_f64() * 1000.0;

    let t5 = Instant::now();
    let hits = doc.search("attention")?;
    let search_ms = t5.elapsed().as_secs_f64() * 1000.0;

    println!("pages: {}", pages);
    println!("headings: {}", st.headings.len());
    println!("open: {:.1} ms", open_ms);
    println!("structure (first call, including extraction of all pages): {:.1} ms", struct_ms);
    println!("structure (cache): {:.2} ms", struct_cached_ms);
    println!("layout JSON of all pages: {:.1} ms", layouts_ms);
    println!("render page 0 @2x: {:.1} ms", render_ms);
    println!("search \"attention\": {:.1} ms, {} hits", search_ms, hits.hits.len());
    Ok(())
}
