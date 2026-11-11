//! JSON-модели, строго по CONTRACT.md §3–§5 (camelCase, bbox:{x,y,w,h}).
//!
//! Все значения санитизируются: NaN/Infinity не попадают в JSON, координаты
//! округляются до 1e-3, размеры шрифта — до 0.1.

use serde::{Deserialize, Serialize};

pub fn r3(v: f64) -> f64 {
    if v.is_finite() {
        (v * 1000.0).round() / 1000.0
    } else {
        0.0
    }
}

pub fn r1(v: f64) -> f64 {
    if v.is_finite() {
        (v * 10.0).round() / 10.0
    } else {
        0.0
    }
}

/// Прямоугольник в точках PDF, origin top-left, y вниз.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self {
            x: r3(if x.is_finite() { x } else { 0.0 }),
            y: r3(if y.is_finite() { y } else { 0.0 }),
            w: r3(if w.is_finite() { w.max(0.0) } else { 0.0 }),
            h: r3(if h.is_finite() { h.max(0.0) } else { 0.0 }),
        }
    }

    pub fn from_ltrb(l: f64, t: f64, r: f64, b: f64) -> Self {
        let l = if l.is_finite() { l } else { 0.0 };
        let t = if t.is_finite() { t } else { 0.0 };
        let r = if r.is_finite() { r } else { l };
        let b = if b.is_finite() { b } else { t };
        Self::new(l.min(r), t.min(b), (r - l).abs(), (b - t).abs())
    }

    pub fn right(&self) -> f64 {
        self.x + self.w
    }

    pub fn bottom(&self) -> f64 {
        self.y + self.h
    }

    pub fn center_x(&self) -> f64 {
        self.x + self.w * 0.5
    }

    pub fn center_y(&self) -> f64 {
        self.y + self.h * 0.5
    }

    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }

    pub fn area(&self) -> f64 {
        self.w * self.h
    }

    pub fn union(self, o: Rect) -> Rect {
        Rect::from_ltrb(
            self.x.min(o.x),
            self.y.min(o.y),
            self.right().max(o.right()),
            self.bottom().max(o.bottom()),
        )
    }

    /// Площадь пересечения (0 если не пересекаются).
    pub fn intersect_area(&self, o: &Rect) -> f64 {
        let l = self.x.max(o.x);
        let t = self.y.max(o.y);
        let r = self.right().min(o.right());
        let b = self.bottom().min(o.bottom());
        if r <= l || b <= t {
            0.0
        } else {
            (r - l) * (b - t)
        }
    }

    /// Доля горизонтального перекрытия относительно меньшей ширины.
    pub fn x_overlap_ratio(&self, o: &Rect) -> f64 {
        let l = self.x.max(o.x);
        let r = self.right().min(o.right());
        let w = (r - l).max(0.0);
        let min_w = self.w.min(o.w);
        if min_w <= 0.0 {
            0.0
        } else {
            w / min_w
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Font {
    pub name: String,
    pub size: f64,
    pub bold: bool,
    pub italic: bool,
    pub monospace: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Word {
    pub text: String,
    pub bbox: Rect,
    pub size: f64,
    pub bold: bool,
    pub italic: bool,
    pub font: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub bbox: Rect,
    pub text: String,
    pub baseline_y: f64,
    pub words: Vec<Word>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BlockKind {
    Body,
    Heading,
    List,
    Caption,
    Table,
    Code,
    Header,
    Footer,
    Formula,
    Quote,
    Reference,
}

impl BlockKind {
    pub fn as_str(self) -> &'static str {
        match self {
            BlockKind::Body => "body",
            BlockKind::Heading => "heading",
            BlockKind::List => "list",
            BlockKind::Caption => "caption",
            BlockKind::Table => "table",
            BlockKind::Code => "code",
            BlockKind::Header => "header",
            BlockKind::Footer => "footer",
            BlockKind::Formula => "formula",
            BlockKind::Quote => "quote",
            BlockKind::Reference => "reference",
        }
    }

    /// Может ли строка этого kind продолжаться на следующей строке.
    pub fn continues(self) -> bool {
        matches!(
            self,
            BlockKind::Body
                | BlockKind::List
                | BlockKind::Caption
                | BlockKind::Code
                | BlockKind::Formula
                | BlockKind::Quote
                | BlockKind::Reference
                | BlockKind::Table
        )
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Block {
    pub id: String,
    pub kind: BlockKind,
    pub level: i32,
    pub text: String,
    pub bbox: Rect,
    pub font: Font,
    pub confidence: f64,
    pub lines: Vec<Line>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageLayout {
    pub schema: i32,
    pub index: i32,
    pub width: f64,
    pub height: f64,
    pub rotation: i32,
    pub body_font_size: f64,
    pub blocks: Vec<Block>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Heading {
    pub id: String,
    pub page: i32,
    pub level: i32,
    pub title: String,
    pub bbox: Rect,
    pub confidence: f64,
    pub source: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlineItem {
    pub title: String,
    pub page: i32,
    pub level: i32,
    pub children: Vec<OutlineItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub body_font_size: f64,
    pub size_clusters: Vec<f64>,
    pub page_count: i32,
    pub tagged: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentStructure {
    pub schema: i32,
    pub title: Option<String>,
    pub page_count: i32,
    pub tagged: bool,
    pub outline: Vec<OutlineItem>,
    pub headings: Vec<Heading>,
    pub metrics: Metrics,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub page: i32,
    pub rects: Vec<Rect>,
    pub snippet: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub query: String,
    pub hits: Vec<SearchHit>,
}

/// Страница целиком: layout + метаданные для классификации.
#[derive(Clone, Debug)]
pub struct PageData {
    pub layout: PageLayout,
    pub line_meta: Vec<LineMeta>,
    pub char_count: usize,
}

/// Внутренние признаки строки, нужные классификатору (в JSON не уходят).
#[derive(Clone, Debug, Default)]
pub struct LineMeta {
    pub page: i32,
    pub size: f64,
    pub bold_ratio: f64,
    pub italic_ratio: f64,
    pub mono_ratio: f64,
    pub math_ratio: f64,
    pub char_count: usize,
    pub norm_text: String,
    pub zone: Zone,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Zone {
    Top,
    #[default]
    Middle,
    Bottom,
}

impl Zone {
    pub fn of(rect: &Rect, page_h: f64) -> Zone {
        if page_h <= 0.0 {
            return Zone::Middle;
        }
        let c = rect.center_y() / page_h;
        if c < 0.14 {
            Zone::Top
        } else if c > 0.86 {
            Zone::Bottom
        } else {
            Zone::Middle
        }
    }
}
