//! Element classification (CONTRACT §6): headings, lists, captions, code,
//! formulas, headers/footers, references. Typography heuristics only.

use crate::json_types::{BlockKind, Zone};
use crate::text::RawLine;
use std::collections::HashMap;

#[derive(Clone, Debug, Default)]
pub struct HeadingSignal {
    /// 0..1, candidate threshold is 0.55.
    pub score: f64,
    /// For numbered headings: «1 Introduction» → 1, «3.1 …» → 2.
    pub numbered_depth: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct ClassifiedLine {
    pub raw: RawLine,
    pub kind: BlockKind,
    pub heading: Option<HeadingSignal>,
}

/// Document context needed to classify a single line.
pub struct ClassifyCtx {
    pub page_count: i32,
    pub body_size: f64,
    /// Precomputed headers/footers: (page, normalized text) → kind.
    pub header_footer: HashMap<(i32, String), BlockKind>,
}

impl ClassifyCtx {
    pub fn new(page_count: i32, body_size: f64) -> Self {
        Self {
            page_count,
            body_size,
            header_footer: HashMap::new(),
        }
    }
}

pub fn classify_line(raw: &RawLine, ctx: &ClassifyCtx) -> ClassifiedLine {
    let heading = heading_signal(raw, ctx);

    let mut kind = BlockKind::Body;
    if let Some(k) = ctx.header_footer.get(&(raw.page, raw.norm_text.clone())) {
        kind = *k;
    } else if raw.zone != Zone::Middle && is_page_number(&raw.line.text) {
        kind = if raw.zone == Zone::Top {
            BlockKind::Header
        } else {
            BlockKind::Footer
        };
    } else if raw.mono_ratio > 0.6 {
        kind = BlockKind::Code;
    } else if is_formula(raw) {
        kind = BlockKind::Formula;
    } else {
        let strong_heading = heading.as_ref().map(|h| h.score >= 0.55).unwrap_or(false);
        if strong_heading {
            kind = BlockKind::Heading;
        } else if is_caption(raw) {
            kind = BlockKind::Caption;
        } else if is_list_item(raw) {
            kind = BlockKind::List;
        } else if is_reference(raw, ctx) {
            kind = BlockKind::Reference;
        } else if is_quote(raw) {
            kind = BlockKind::Quote;
        }
    }

    let heading = if kind == BlockKind::Heading {
        heading
    } else {
        None
    };

    ClassifiedLine {
        raw: raw.clone(),
        kind,
        heading,
    }
}

// ---------------------------------------------------------------------------
// Headings
// ---------------------------------------------------------------------------

pub fn heading_signal(raw: &RawLine, ctx: &ClassifyCtx) -> Option<HeadingSignal> {
    let text = raw.line.text.trim();
    let n = text.chars().count();
    if n == 0 || n > 180 {
        return None;
    }
    let body = if ctx.body_size > 0.0 {
        ctx.body_size
    } else {
        10.0
    };
    let ratio = raw.size / body;
    let bold = raw.bold_ratio >= 0.55;
    let numbered = numbering_depth(text);
    let mut score: f64 = 0.0;

    if ratio >= 1.12 {
        score += 0.42 + 0.30 * ((ratio - 1.12) / 1.4).min(1.0);
    } else if ratio >= 1.04 {
        score += 0.10;
    }
    if bold && ratio >= 0.97 && n < 90 {
        score += 0.30;
    } else if bold {
        score += 0.08;
    }
    if numbered.is_some() {
        score += 0.24;
    }
    if is_common_section_name(text) {
        score += 0.30;
    }
    if is_all_caps(text) && n <= 60 && ratio >= 0.9 {
        score += 0.16;
    }
    if n <= 55 {
        score += 0.05;
    }
    if centered(raw) && n <= 70 {
        score += 0.08;
    }
    if raw.zone == Zone::Top && raw.line.bbox.y < 0.35 * raw.page_h {
        score += 0.03;
    }
    // penalties
    let last = text.chars().last().unwrap_or(' ');
    if matches!(last, '.' | ',' | ';' | ':') {
        score -= 0.45;
    }
    if n > 110 {
        score -= 0.30;
    }
    if ratio < 1.03 && !bold && numbered.is_none() {
        score -= 0.25;
    }
    if text
        .chars()
        .next()
        .map(|c| c.is_lowercase())
        .unwrap_or(false)
    {
        score -= 0.20;
    }
    if text.split_whitespace().count() > 16 && !bold && ratio < 1.12 {
        score -= 0.20;
    }
    if raw.line.bbox.w > 0.90 * raw.page_w && !bold {
        score -= 0.15;
    }
    let score = score.clamp(0.0, 1.0);
    if score >= 0.55 {
        Some(HeadingSignal {
            score: round2(score),
            numbered_depth: numbered,
        })
    } else {
        None
    }
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Heading numbering depth: «1 Introduction» → 1, «3.1 Encoder» → 2,
/// «1.2.3 …» → 3, «Chapter 2» → 1, «IV. …» → 1.
pub fn numbering_depth(text: &str) -> Option<i32> {
    let t = text.trim_start();
    // "1", "1.", "1.2", "1.2.3" + space + word (not a lowercase list item "1. foo")
    let mut i = 0;
    let bytes = t.as_bytes();
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i > 0 && i <= 3 {
        let mut depth = 1;
        let mut j = i;
        loop {
            if j < bytes.len() && bytes[j] == b'.' {
                let k = j + 1;
                let mut m = k;
                while m < bytes.len() && bytes[m].is_ascii_digit() {
                    m += 1;
                }
                if m > k {
                    depth += 1;
                    j = m;
                } else {
                    // dot at the end of the number: "1." is just a separator
                    j = k;
                    break;
                }
            } else {
                break;
            }
        }
        // after the number there must be a separator/end and a word
        while j < bytes.len() && (bytes[j] == b'.' || bytes[j] == b')') {
            j += 1;
        }
        let rest = &t[j..];
        let rest = rest.trim_start();
        if !rest.is_empty() {
            let first = rest.chars().next().unwrap();
            // After the number comes a capitalized word (not «3.3 · 10» / «1. foo»).
            let looks_like_heading_word = first.is_alphabetic() && first.is_uppercase();
            if looks_like_heading_word && text.chars().count() <= 140 {
                return Some(depth.min(6));
            }
        }
        return None;
    }
    let lower = t.to_lowercase();
    for (kw, depth) in [
        ("chapter", 1),
        ("глава", 1),
        ("part", 1),
        ("часть", 1),
        ("section", 2),
        ("раздел", 2),
        ("appendix", 1),
        ("приложение", 1),
    ] {
        if let Some(rest) = lower.strip_prefix(kw) {
            let r = rest.trim_start();
            if r.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
                return Some(depth);
            }
        }
    }
    // roman numerals: "IV. Method" / "IV Method"
    let mut roman = 0;
    for c in t.chars() {
        if matches!(c, 'I' | 'V' | 'X' | 'L' | 'C') {
            roman += 1;
        } else {
            break;
        }
    }
    if roman >= 1 && roman <= 6 {
        let rest = t[roman..].trim_start_matches(['.', ')', ' ']);
        if !rest.is_empty()
            && rest.chars().next().map(|c| c.is_uppercase()).unwrap_or(false)
            && t.chars().count() <= 120
        {
            return Some(1);
        }
    }
    None
}

/// Common section names: their heading is recognized even at a font size close to
/// the body size (bold + a known name).
pub fn is_common_section_name(text: &str) -> bool {
    let t = text.trim().to_lowercase();
    let t = t.trim_end_matches([':', '.', ' ']).to_string();
    const NAMES: &[&str] = &[
        "abstract",
        "introduction",
        "conclusion",
        "conclusions",
        "references",
        "bibliography",
        "appendix",
        "acknowledgments",
        "acknowledgements",
        "related work",
        "background",
        "введение",
        "заключение",
        "литература",
        "список литературы",
        "приложение",
        "благодарности",
        "аннотация",
        "содержание",
    ];
    NAMES.iter().any(|n| t == *n)
}

pub fn is_all_caps(s: &str) -> bool {
    let mut alpha = 0;
    let mut upper = 0;
    for c in s.chars() {
        if c.is_alphabetic() {
            alpha += 1;
            if c.is_uppercase() {
                upper += 1;
            }
        }
    }
    alpha >= 2 && upper as f64 / alpha as f64 >= 0.8
}

fn centered(raw: &RawLine) -> bool {
    if raw.page_w <= 0.0 {
        return false;
    }
    (raw.line.bbox.center_x() - raw.page_w * 0.5).abs() < 0.07 * raw.page_w
        && raw.line.bbox.w < 0.8 * raw.page_w
}

// ---------------------------------------------------------------------------
// Other kinds
// ---------------------------------------------------------------------------

fn is_page_number(text: &str) -> bool {
    let t = text.trim();
    if t.is_empty() || t.chars().count() > 40 {
        return false;
    }
    let lower = t.to_lowercase();
    let stripped: String = t
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect();
    let compact = stripped.trim();
    // digits only
    if !compact.is_empty() && compact.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    // roman numeral only
    if !compact.is_empty()
        && compact.chars().count() <= 8
        && compact
            .chars()
            .all(|c| matches!(c, 'I' | 'V' | 'X' | 'L' | 'C' | 'i' | 'v' | 'x' | 'l' | 'c'))
    {
        return true;
    }
    // "page 3 of 15", "- 3 -", "3 / 15"
    for pfx in ["стр.", "стр", "page", "p.", "с."] {
        if lower.starts_with(pfx) && compact.chars().any(|c| c.is_ascii_digit()) {
            return true;
        }
    }
    let digits = compact.chars().filter(|c| c.is_ascii_digit()).count();
    let words: Vec<&str> = lower.split_whitespace().collect();
    digits > 0
        && words.len() <= 4
        && compact.chars().count() <= 12
        && words
            .iter()
            .all(|w| w.chars().all(|c| c.is_ascii_digit() || c == '/' || c == '-' || c == '–'))
}

fn is_caption(raw: &RawLine) -> bool {
    let t = raw.line.text.trim_start();
    if t.is_empty() {
        return false;
    }
    let lower = t.to_lowercase();
    const PREFIXES: &[&str] = &[
        "figure", "fig.", "fig ", "table", "tab.", "tab ", "listing", "algorithm", "рис.",
        "рис ", "табл.", "табл ", "схема", "diagram", "example", "пример",
    ];
    if !PREFIXES.iter().any(|p| lower.starts_with(p)) {
        return false;
    }
    // after the prefix we expect a number or a colon
    let rest = &lower[PREFIXES
        .iter()
        .find(|p| lower.starts_with(**p))
        .map(|p| p.len())
        .unwrap_or(0)..];
    let rest_trim = rest.trim_start();
    let has_number = rest_trim
        .chars()
        .next()
        .map(|c| c.is_numeric() || matches!(c, ':' | '.'))
        .unwrap_or(false);
    has_number && t.chars().count() <= 260
}

fn is_list_item(raw: &RawLine) -> bool {
    let t = raw.line.text.trim_start();
    let mut chars = t.chars();
    let first = match chars.next() {
        Some(c) => c,
        None => return false,
    };
    if matches!(
        first,
        '•' | '◦' | '▪' | '●' | '–' | '-' | '*' | '·' | '—' | '‣' | '⁃'
    ) {
        return true;
    }
    // "1. ", "12) ", "a) ", "(1) "
    if first == '(' {
        let mut digs = 0;
        for c in chars {
            if c.is_ascii_digit() || c.is_alphabetic() {
                digs += 1;
            } else {
                return c == ')' && digs > 0;
            }
        }
        return false;
    }
    if first.is_ascii_digit() || first.is_alphabetic() {
        let mut count = 1;
        let mut marker_end: Option<char> = None;
        let mut prev = first;
        for c in chars {
            if prev.is_ascii_digit() || prev.is_alphabetic() {
                if c == '.' || c == ')' {
                    marker_end = Some(c);
                    if prev.is_ascii_digit() || prev.is_alphabetic() {
                        // the marker is "1.", "12)", "a)"
                    }
                    break;
                }
            }
            if !(c.is_ascii_digit() || c.is_ascii_alphabetic()) {
                break;
            }
            count += 1;
            prev = c;
            if count > 4 {
                break;
            }
        }
        if marker_end.is_some() && count <= 3 {
            // the character after the marker must be a space
            let marker_len = count + 1;
            let after: String = t.chars().skip(marker_len).take(1).collect();
            if after.chars().all(|c| c.is_whitespace()) {
                return true;
            }
        }
    }
    false
}

fn is_formula(raw: &RawLine) -> bool {
    if raw.char_count == 0 {
        return false;
    }
    if raw.math_ratio > 0.45 {
        return true;
    }
    let t = raw.line.text.trim();
    if t.is_empty() || t.chars().count() > 120 {
        return false;
    }
    let total = t.chars().count() as f64;
    let mathish = t
        .chars()
        .filter(|c| {
            matches!(
                c,
                '=' | '+'
                    | '-'
                    | '−'
                    | '×'
                    | '÷'
                    | '±'
                    | '∑'
                    | '∏'
                    | '∫'
                    | '√'
                    | '∞'
                    | '≤'
                    | '≥'
                    | '≠'
                    | '≈'
                    | '→'
                    | '←'
                    | '↔'
                    | '∂'
                    | '∇'
                    | '∈'
                    | '∀'
                    | '∃'
                    | '∘'
                    | '∗'
                    | '·'
                    | '^'
                    | '_'
                    | 'α'
                    | 'β'
                    | 'γ'
                    | 'δ'
                    | 'ε'
                    | 'θ'
                    | 'λ'
                    | 'μ'
                    | 'σ'
                    | 'τ'
                    | 'φ'
                    | 'ω'
            )
        })
        .count() as f64;
    let alpha_words = t
        .split_whitespace()
        .filter(|w| w.chars().filter(|c| c.is_alphabetic()).count() >= 3)
        .count();
    mathish / total >= 0.18 && alpha_words <= 3
}

fn is_reference(raw: &RawLine, ctx: &ClassifyCtx) -> bool {
    let page_count = ctx.page_count.max(1) as f64;
    let frac = (raw.page as f64 + 0.5) / page_count;
    if frac < 0.72 || ctx.body_size <= 0.0 {
        return false;
    }
    let t = raw.line.text.trim_start();
    let small = raw.size < ctx.body_size * 0.96;
    let bracketed = t.starts_with('[')
        && t.chars()
            .skip(1)
            .take_while(|c| c.is_ascii_digit())
            .count()
            >= 1;
    (small && raw.char_count <= 500) || bracketed
}

fn is_quote(raw: &RawLine) -> bool {
    if raw.page_w <= 0.0 {
        return false;
    }
    let indented = raw.line.bbox.x > 0.14 * raw.page_w
        && raw.line.bbox.right() < 0.90 * raw.page_w
        && raw.line.bbox.w < 0.75 * raw.page_w;
    indented && raw.italic_ratio > 0.5 && raw.char_count >= 10
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json_types::{Line, Rect};
    use crate::text::RawLine;

    fn line(text: &str, size: f64, bold: bool, y: f64, zone: Zone) -> RawLine {
        let bbox = Rect::new(70.0, y, 200.0, size * 0.75);
        RawLine {
            page: 0,
            page_w: 612.0,
            page_h: 792.0,
            line: Line {
                bbox,
                text: text.to_string(),
                baseline_y: y + size * 0.75,
                words: Vec::new(),
            },
            size,
            bold_ratio: if bold { 1.0 } else { 0.0 },
            italic_ratio: 0.0,
            mono_ratio: 0.0,
            math_ratio: 0.0,
            char_count: text.chars().count(),
            norm_text: crate::text::normalize_for_repeat(text),
            zone,
        }
    }

    fn ctx() -> ClassifyCtx {
        ClassifyCtx::new(10, 10.0)
    }

    #[test]
    fn numbered_bold_is_heading() {
        let c = classify_line(&line("1 Introduction", 12.0, true, 100.0, Zone::Middle), &ctx());
        assert_eq!(c.kind, BlockKind::Heading);
        assert_eq!(c.heading.as_ref().unwrap().numbered_depth, Some(1));
    }

    #[test]
    fn body_sentence_is_not_heading() {
        let c = classify_line(
            &line(
                "The dominant sequence transduction models are based on complex recurrent networks.",
                10.0,
                false,
                200.0,
                Zone::Middle,
            ),
            &ctx(),
        );
        assert_eq!(c.kind, BlockKind::Body);
        assert!(c.heading.is_none());
    }

    #[test]
    fn figure_caption_is_caption() {
        let c = classify_line(
            &line("Figure 1: The Transformer model architecture.", 9.0, false, 400.0, Zone::Middle),
            &ctx(),
        );
        assert_eq!(c.kind, BlockKind::Caption);
        let c = classify_line(
            &line("Рис. 1. Пример подписи к иллюстрации", 9.0, false, 400.0, Zone::Middle),
            &ctx(),
        );
        assert_eq!(c.kind, BlockKind::Caption);
    }

    #[test]
    fn bullet_is_list() {
        let c = classify_line(&line("• размер шрифта больше медианного", 10.0, false, 300.0, Zone::Middle), &ctx());
        assert_eq!(c.kind, BlockKind::List);
    }

    #[test]
    fn page_number_in_footer_zone_is_footer() {
        let c = classify_line(&line("12", 9.0, false, 760.0, Zone::Bottom), &ctx());
        assert_eq!(c.kind, BlockKind::Footer);
        let c = classify_line(&line("Стр. 3 из 10", 9.0, false, 760.0, Zone::Bottom), &ctx());
        assert_eq!(c.kind, BlockKind::Footer);
    }

    #[test]
    fn header_footer_from_document_map() {
        let mut c = ClassifyCtx::new(3, 10.0);
        c.header_footer.insert(
            (0, crate::text::normalize_for_repeat("Folio · демонстрационный документ")),
            BlockKind::Header,
        );
        let l = line("Folio · демонстрационный документ", 8.0, false, 24.0, Zone::Top);
        let cl = classify_line(&l, &c);
        assert_eq!(cl.kind, BlockKind::Header);
    }

    #[test]
    fn mono_line_is_code() {
        let mut l = line("let x = 42;", 10.0, false, 300.0, Zone::Middle);
        l.mono_ratio = 1.0;
        assert_eq!(classify_line(&l, &ctx()).kind, BlockKind::Code);
    }

    #[test]
    fn numbering_depth_levels() {
        assert_eq!(numbering_depth("1 Introduction"), Some(1));
        assert_eq!(numbering_depth("3.1 Encoder and Decoder Stacks"), Some(2));
        assert_eq!(numbering_depth("3.2.1 Scaled Dot-Product Attention"), Some(3));
        assert_eq!(numbering_depth("2.1. Как это устроено"), Some(2));
        assert_eq!(numbering_depth("IV. Метод"), Some(1));
        assert_eq!(numbering_depth("3.3 · 10"), None);
        assert_eq!(numbering_depth("ordinary sentence"), None);
    }

    #[test]
    fn common_section_names() {
        assert!(is_common_section_name("Abstract"));
        assert!(is_common_section_name("References"));
        assert!(is_common_section_name("литература"));
        assert!(!is_common_section_name("Attention Is All You Need"));
    }
}
