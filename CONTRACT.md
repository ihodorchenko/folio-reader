# Folio — contract between the Rust core and the macOS app

Single source of truth. Change it only after agreement with the maintainers.

```
.
├── CONTRACT.md            ← this file
├── scripts/               ← build, packaging and acceptance scripts
├── core/                  ← Rust core
│   ├── Cargo.toml
│   ├── src/...
│   ├── include/pdfcore.h
│   └── vendor/pdfium/     ← libpdfium.dylib + headers (already downloaded)
├── app/                   ← SwiftUI/AppKit app
│   ├── Package.swift
│   └── Sources/Folio/
│       ├── Core/          ← models, protocol, dlopen bridge
│       └── App/ UI/ Interaction/ Model/
└── samples/               ← sample PDFs: sample-ru.pdf, no-text.pdf
                            (attention.pdf is not committed; scripts/fetch-samples.sh downloads it)
```

## 0. Environment

```bash
export REPO_ROOT="$PWD"                  # repository root
export RUSTUP_HOME="$REPO_ROOT/../.toolchain/rustup"
export CARGO_HOME="$REPO_ROOT/../.toolchain/cargo"
export PATH="$CARGO_HOME/bin:$PATH"
cd core && cargo build --release         # targets: staticlib + cdylib
```

Rust is not on `PATH` in the reference development environment: the toolchain lives in a
workspace-local `.toolchain` directory next to the checkout. With a stock rustup installation,
skip the `RUSTUP_HOME`/`CARGO_HOME` exports.

PDFium: `core/vendor/pdfium/libpdfium.dylib` (7.5 MB, chrome/8152, BSD-3), headers in
`core/vendor/pdfium/fpdf*.h`. This is a prebuilt binary; PDFium itself is not built here.

Swift: `swift build` from `app/`, Swift 6.4, macOS 27, arm64.

## 1. C ABI (`core/include/pdfcore.h`)

```c
typedef struct PcDocument PcDocument;

PcDocument *pc_open(const char *path);          // NULL on error
void        pc_close(PcDocument *doc);
int32_t     pc_page_count(const PcDocument *doc);
double      pc_page_width(const PcDocument *doc, int32_t page);   // points after /Rotate
double      pc_page_height(const PcDocument *doc, int32_t page);

/* scale: 1.0 == 72 dpi. The reader renders to BGRA (byte order B,G,R,A),
   alpha is always 255, the background is filled white.
   IMPORTANT: PDFium fills the bitmap bottom-up, so the core must flip the
   rows: buffer row 0 is the TOP row of the image (Swift wraps the buffer in a
   CGImage without flipping).
   For pages with /Rotate != 0 both the dimensions and the content are in the
   displayed orientation.
   Free the buffer with pc_free_buffer.
   Returns: 0 = ok, <0 = error (pc_last_error). */
int32_t pc_render_page(const PcDocument *doc, int32_t page, double scale,
                       int32_t *out_w, int32_t *out_h, uint8_t **out_bgra);

/* Heap-allocated UTF-8 JSON, free with pc_free_json. NULL on error. */
char *pc_page_layout_json(const PcDocument *doc, int32_t page);
char *pc_document_structure_json(const PcDocument *doc);
char *pc_search_json(const PcDocument *doc, const char *query);   // up to 500 hits

void pc_free_buffer(void *ptr);
void pc_free_json(char *ptr);
const char *pc_last_error(void);   // thread-local, UTF-8, valid until the next call
const char *pc_version(void);      // "pdfcore 0.1.0 / pdfium 8152"
```

Requirements:
* All functions are thread-safe: a single global `Mutex` wraps every PDFium call.
* `pc_open` does not keep the file locked longer than necessary.
* A corrupt or encrypted PDF makes `pc_open` return NULL; `pc_last_error()` explains why.
* `pc_page_layout_json` and `pc_document_structure_json` cache their result per document
  (cheap when called again from the UI thread).

## 2. Coordinate system

PDF points only (1/72"), **origin = top-left corner, y increases downward**, page dimensions
after `/Rotate` is applied. PDFium reports the same way (`FPDFText_GetCharBox` returns an
origin at the bottom-left, so the core must flip y: `top = pageH - box.top`).
Rendering also accounts for rotation (PDFium `FPDF_RenderPageBitmap` with rotate).

## 3. JSON: page (`pc_page_layout_json`)

```json
{
  "schema": 1,
  "index": 0,
  "width": 612.0,
  "height": 792.0,
  "rotation": 0,
  "bodyFontSize": 10.0,
  "blocks": [
    {
      "id": "p0b3",                       // stable within a document
      "kind": "heading",                  // body|heading|list|caption|table|code|header|footer|formula|quote|reference
      "level": 1,                         // 1..6 for heading, otherwise 0
      "text": "1 Introduction",
      "bbox": {"x": 69.4, "y": 96.2, "w": 240.6, "h": 16.4},
      "font": {"name": "NimbusRomNo9L-Medi", "size": 14.0,
               "bold": true, "italic": false, "monospace": false},
      "confidence": 0.92,
      "lines": [
        {"bbox": {"x":69.4,"y":96.2,"w":240.6,"h":14.0}, "text": "1 Introduction",
         "baselineY": 108.1,
         "words": [
           {"text":"1","bbox":{"x":69.4,"y":99.1,"w":8.2,"h":11.1},
            "size":14.0,"bold":true,"italic":false,"font":"NimbusRomNo9L-Medi"}
         ]}
      ]
    }
  ]
}
```

Rules:
* `bbox` is the bounding rectangle of a block/line/word; words do not overlap.
* Words are the smallest unit for hit-testing and "Look Up". Split on spaces and on gaps
  > ~0.25 em; join words hyphenated across a line break (`hyphen-` + `ated`) but keep the
  original bbox.
* Block `text` has normalized spaces and no line breaks; it is meant for reading and speech.
* `bodyFontSize` is the mode of the font size weighted by the page character count.
* The JSON must not contain NaN/Infinity (valid JSON).

## 4. JSON: document structure (`pc_document_structure_json`)

```json
{
  "schema": 1,
  "title": "Attention Is All You Need",
  "pageCount": 15,
  "tagged": false,                       // whether /StructTreeRoot is present
  "outline": [                            // PDF bookmarks (may be empty)
    {"title": "1 Introduction", "page": 0, "level": 0,
     "children": [{"title": "3.1 Encoder ...", "page": 2, "level": 1, "children": []}]}
  ],
  "headings": [                           // flat list sorted in document order
    {"id": "p0b3", "page": 0, "level": 1, "title": "1 Introduction",
     "bbox": {"x":69.4,"y":96.2,"w":240.6,"h":16.4}, "confidence": 0.95,
     "source": "heuristic"}               // heuristic | tagged | outline
  ],
  "metrics": {"bodyFontSize": 10.0, "sizeClusters": [14.0, 12.0, 10.0],
              "pageCount": 15, "tagged": false}
}
```

Levels: 1 is the largest headings (parts/chapters), 2, 3… are subordinate ones. Levels are
assigned by clustering sizes/weights **across the whole document**, not per page, so the same
heading always gets the same level. `source: "tagged"` when the level came from the PDF
structure tree (H1..H6); otherwise `heuristic`.
If bookmarks exist, `outline` is filled from them; if not, `outline` may be built from
headings (then `source: "heuristic"`), but the app is able to build the tree itself.

## 5. JSON: search (`pc_search_json`)

```json
{"query": "attention", "hits": [
  {"page": 0, "rects": [{"x":1,"y":2,"w":3,"h":4}], "snippet": "...attention..."}
]}
```
Search is case-insensitive for Latin/Cyrillic (PDFium FindStart + FPDF_MATCHCASE=0).

## 6. Element classification (mandatory heuristics)

Headings (the user's main requirement — they must be "detected reliably"):
1. the cluster font size > bodyFontSize * 1.12, or bold at a size >= body*0.98 with a short
   line (< 90 characters, < 3 lines), or text shaped like "Chapter N", "N.", "N.N",
   "Introduction" in caps, Roman numerals;
2. a single line with larger spacing above/below than the line spacing;
3. it does not end with a period/comma (except "…?"), it is not a paragraph continuation;
4. the level is the rank of the cluster (size, weight) among all candidate headings in the document;
5. header/footer rejection: text repeated at the top/bottom of >= 3 pages.
Additionally: page numbers and folios → `header`/`footer`; figure captions
(`Figure`/`Fig.`/`Table`/`Tab.`) → `caption`; markers `• - – 1. a)` → `list`;
a monospaced font → `code`; formulas (many characters in math fonts) → `formula`;
paragraphs in a smaller font size at the end → `reference`.

## 7. Swift models and protocol

`app/Sources/Folio/Core/DocumentModel.swift`, `DocumentProviding.swift`:

```swift
struct PcRect: Codable, Hashable { var x, y, w, h: Double }
struct PcFont: Codable, Hashable { var name: String; var size: Double; var bold, italic, monospace: Bool }
struct PcWord: Codable, Hashable { var text: String; var bbox: PcRect; var size: Double
                                   var bold: Bool; var italic: Bool; var font: String }
struct PcLine: Codable, Hashable { var bbox: PcRect; var text: String; var baselineY: Double
                                   var words: [PcWord] }
enum PcBlockKind: String, Codable { case body, heading, list, caption, table, code, header, footer, formula, quote, reference }
struct PcBlock: Codable, Hashable { var id: String; var kind: PcBlockKind; var level: Int
                                    var text: String; var bbox: PcRect; var font: PcFont
                                    var confidence: Double; var lines: [PcLine] }
struct PcPageLayout: Codable { var index: Int; var width, height: Double; var rotation: Int
                               var bodyFontSize: Double; var blocks: [PcBlock] }
struct PcHeading: Codable, Hashable { var id: String; var page: Int; var level: Int
                                      var title: String; var bbox: PcRect; var source: String }
struct PcOutlineItem: Codable, Hashable { var title: String; var page: Int; var level: Int
                                          var children: [PcOutlineItem] }
struct PcDocumentStructure: Codable { var title: String?; var pageCount: Int; var tagged: Bool
                                      var headings: [PcHeading]; var outline: [PcOutlineItem] }
struct PcSearchHit: Codable, Hashable { var page: Int; var rects: [PcRect]; var snippet: String }

@MainActor protocol DocumentProviding: AnyObject {
  var fingerprint: String { get }                 // path+size+date, for caches
  func structure() throws -> PcDocumentStructure
  func pageLayout(_ index: Int) throws -> PcPageLayout
  func pageSize(_ index: Int) throws -> (width: Double, height: Double)
  func render(_ index: Int, scale: Double) throws -> CGImage
  func search(_ query: String) throws -> [PcSearchHit]
  var isMock: Bool { get }
}
```

Rendering returns a `CGImage` (BGRA → `CGBitmapInfo.byteOrder32Little + .noneSkipFirst`).
The bridge implements the protocol through `dlopen("libpdfcore.dylib")`; when the dylib is
missing it falls back to `MockDocumentProvider` with `isMock == true` (the UI then shows a
yellow "core not built" banner). Nothing links against Rust at Swift build time: the app
builds without the core.

## 8. What the app must do (accepted by the maintainers)

1. Open a PDF (⌘O, drag&drop, command-line argument) and remember the last document.
2. Continuous page scrolling, retina rendering, zoom (⌘+/⌘−/pinch); rotating the window does not break it.
3. A system-reader-style sidebar: a "Structure" tab (heading tree with levels, click →
   jump to the block), a "Pages" tab (thumbnails), a "Search" tab (results, highlighting).
4. Text overlay: hover highlights a word; drag selects; ⌘C copies.
5. **Force click on a word → the system dictionary** via
   `NSView.showDefinition(for:at:)`; also ⌘D and a context-menu item.
   Requires `NSPressureConfiguration(pressureBehavior: .primaryDeepClick)` and
   `pressureChange(with:)` → `event.stage == 2`.
6. A debug "Show layout" mode: colored block frames by kind plus labels, so the quality of
   heading/element detection can be inspected by eye.
7. Dark/light appearance, sidebar vibrancy, SF Symbols, unified toolbar — "like the system".

## 9. Core acceptance criteria

* `attention.pdf` (15 pages, untagged): the title and all numbered sections 1..7 are found,
  subsections 3.1..3.5 and 6.1/6.2 get level 2; false headings (body text) < 5%.
* attention.pdf headers/footers never end up in headings.
* `pc-cli` supports: `info`, `text --page N`, `structure`, `render --page N --out x.png`.
* `time pc_document_structure_json(attention.pdf)` < 1.5 s on an M1 Pro.
* cargo test is green; the JSON is valid (checked with `python -m json.tool`).
