# Folio

A native macOS PDF reader with a **Rust/PDFium** rendering core, recovered document
structure (headings, lists, captions, headers/footers, …) and the system dictionary on a
**force click** — in the spirit of Preview and Books.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Rust](https://img.shields.io/badge/core-Rust%201.92%2B-b7410e)
![Swift](https://img.shields.io/badge/UI-Swift%206%20%2B%20SwiftUI%2FAppKit-f05138)
![License](https://img.shields.io/badge/license-MIT-blue)

![Folio main window](docs/root.png)

The sidebar shows a heading tree recovered from the PDF typography; the page is rendered by
PDFium inside a Rust core; the toolbar carries the document title, page navigation, zoom,
layout debug mode and search.

| Element layout (debug mode) | Per-word boxes (overlay accuracy check) |
|---|---|
| ![Element layout](docs/debug.png) | ![Word boxes](docs/debug-words.png) |

Cyrillic document ([`samples/sample-ru.pdf`](samples/sample-ru.pdf)) — same structure recovery
and exact word boxes:

| Structure and page | Per-word boxes |
|---|---|
| ![Cyrillic document](docs/ru.png) | ![Cyrillic word boxes](docs/ru-debug-words.png) |

---

## What it does

- **Open PDFs** via `⌘O`, drag & drop, command-line argument or Finder ("Open With → Folio").
- **One window per book** — every window owns an independent `ReaderModel`: opening another PDF
  from Finder (or `⌘N`) opens a new window and leaves the books in the existing windows alone.
  A cold start shows exactly one window, even if the previous session had several.
- **Reading position is restored** — the last document opens on the page, scroll offset and zoom
  where it was left; positions are remembered per document, so returning to a book picks up where
  you stopped.
- **Continuous scrolling** with retina rendering (PDFium → BGRA → `CGImage`), zoom via
  `⌘+` / `⌘−` / `⌘1` / `⌘0` (fit width) and pinch.
- **System-style sidebar** with three tabs:
  - **Structure** — heading tree with levels, page number and source
    (`heuristic` / `tagged` / `outline`); clicking an item scrolls to the block;
  - **Pages** — page thumbnails;
  - **Search** — debounced full-document search, highlighted hits, next/previous navigation.
- **Text overlay** — hovered word highlight, drag selection, `⌘C` copy.
- **Force click → system dictionary** via `NSView.showDefinition(for:at:)`, plus `⌘D` and a
  context-menu item as a fallback for trackpads without Force Touch.
- **Read aloud** — the selected text (or the word under the right click) through the system speech
  synthesizer. **Off by default**; toggle, speed and voice live in Settings (`⌘,`).
- **Translate** — the selected text through the system Translation framework. The default pair is
  **English (US) → Russian**, and a pair the user picks is remembered between launches.
- **Layout debug mode** — colored boxes per element kind (`heading`, `body`, `list`,
  `caption`, `table`, `code`, `header`, `footer`, `formula`, `quote`, `reference`) with
  `kind/level/confidence` labels, and a per-word box mode that proves the overlay is aligned
  with the actual glyphs.
- **Export structure to JSON** for debugging and downstream pipelines.
- **Unified toolbar**: a single sidebar toggle, the document title on the left and the page
  number, zoom, layout, search and overflow actions pinned to the trailing edge — no duplicated
  sidebar buttons (SwiftUI's automatic toggle is removed through AppKit, see
  [WindowChrome.swift](app/Sources/Folio/UI/WindowChrome.swift)).
- Light/dark appearance, vibrant sidebar, SF Symbols.
- Works even **without a built core** — falls back to a demo document and a banner, which is
  handy while developing the UI.

The application UI is currently in Russian; the code, documentation and tooling are in English.

---

## Architecture

```
┌──────────────────────────── macOS app (Swift 6, SwiftUI + AppKit) ─────────────────────────┐
│  ReaderScene (одно окно = одна книга) → RootView / NavigationSplitView                      │
│                                        ReaderModel (@Observable)      PageCanvasView (NSView)│
│  sidebar: Structure | Pages | Search   caches, async loading, search  CGImage rendering,     │
│                                                                       text overlay, hover,   │
│                                                                       selection, force click │
│  Core/DocumentProviding.swift  ← the only interface that knows about the core               │
│  Core/PdfCoreBridge.swift      ← dlopen("libpdfcore.dylib") + C ABI, JSON → Swift models    │
└──────────────────────────────────────────────┬──────────────────────────────────────────────┘
                                               │ dlopen, C ABI (pdfcore.h)
┌──────────────────────────────────────────────┴──────────────────────────────────────────────┐
│  Rust core pdfcore (crate-type: cdylib + staticlib)                                         │
│   ffi.rs       libpdfium.dylib loading (libloading), FPDF_* declarations                    │
│   text.rs      chars → words → lines → blocks; size = FPDFText_GetFontSize × |matrix|       │
│   classify.rs  heading / body / list / caption / table / code / header / footer / …         │
│   structure.rs document-wide level clustering; PDF outlines and StructTree (H1–H6)          │
│   ffi_api.rs   C ABI: open/close/page_count/page_size/render/layout_json/structure_json/... │
└──────────────────────────────────────────────┬──────────────────────────────────────────────┘
                                               │ FPDF_* (C++)
                                     ┌─────────┴──────────┐
                                     │ PDFium (BSD-3)     │ prebuilt dylib from pdfium-binaries
                                     └────────────────────┘
```

The Rust core is loaded with `dlopen`, so building the Swift app never requires Rust
tooling; and the core itself loads PDFium at runtime, which keeps the native build simple.

### Interface contract

[`CONTRACT.md`](CONTRACT.md) is the single source of truth between the layers: C ABI,
JSON schemas for page layout / document structure / search, coordinate system (PDF points,
top-left origin, y down), thread-safety requirements and acceptance criteria. Swift models in
[`app/Sources/Folio/Core/DocumentModel.swift`](app/Sources/Folio/Core/DocumentModel.swift)
mirror the JSON one-to-one.

### Why Rust, and why PDFium

| Option | What it gives | Why it was not used |
|---|---|---|
| **hayro** (pure Rust: `hayro-syntax`, `hayro-interpret`, `hayro-svg`) | parsing + rendering without native dependencies, 1,600+ PDF visual regression suite | text/selection/structure are explicitly out of scope, API still unstable |
| **pdfium-render** (Rust bindings crate) | idiomatic wrappers, MIT/Apache-2.0, text and rendering | we used direct FFI declarations: fewer API-drift surprises, full control over the text matrix and structure trees |
| **mupdf-rs** (MuPDF bindings) | high-quality rendering and text extraction | AGPL / commercial licensing |
| `lopdf`, `pdf` crate | PDF object parsing | no rendering |

The result: **PDFium through hand-written FFI declarations in Rust** with `libloading` —
the most predictable path to reliable structure recovery (per-character boxes, font size,
weight, matrices, `StructTree`).

---

## How structure is recovered

1. **Characters**: `FPDFText_GetUnicode`, char box, effective font size
   (`FPDFText_GetFontSize × |text matrix scale|` — Quartz documents write `Tf=1`, without this
   every size would be "1.0"), weight (`FPDFText_GetFontWeight`), font name and flags.
2. **Words / lines / blocks**: words by spaces and gaps > 0.25 em, hyphenation joined
   (`hyphen-` + `ation`); lines by baseline (sorted by x, otherwise superscript indices split
   words); blocks by columns and style. Reading order is `(page, y, x)`.
3. **Classification**: heading — larger than the median size, bold/font-name hints, numbering
   (`1`, `1.2.3`, `Chapter`, roman numerals), a short single line with vertical spacing;
   list — bullets/numbering; caption — `Figure/Table/Рис./Табл.` prefixes; code — monospace;
   formula — math fonts/symbols; header/footer — text repeated in the top/bottom zone on ≥ 3
   pages; references — small type at the end.
4. **Levels** — clustering of (size, weight) **across the whole document** plus numbering
   depth; PDF bookmarks or a tagged structure tree (H1…H6) are used when present.
5. **Filters**: duplicates, garbage text (letter ratio, interleaved/mixed characters),
   unnumbered candidates after `References`, figure labels, single-symbol footnote blocks.

On the test paper ([`samples/attention.pdf`](samples/attention.pdf), fetched by
`scripts/fetch-samples.sh`) the core finds **25 headings**: L1 — Abstract/1…7/References,
L2 — 3.1–3.5, 5.1–5.4, 6.1–6.3, L3 — 3.2.1–3.2.3, with no headers/footers or garbage.
Performance on M1 Pro (release): full-document structure of 15 pages — 166 ms (cached: 0 ms),
page render at 2× — 8.9 ms, search — 22 ms (97 hits).

---

## Force click → system dictionary

```swift
// PageCanvasView: an NSView with isFlipped = true
override func mouseDown(with event: NSEvent) {
    pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
    mouseDownPoint = pagePoint(from: event)          // point in page coordinates
    ...
}

override func pressureChange(with event: NSEvent) {
    guard event.stage == 2 else { return }           // stage 2 == deep press
    lookUp(at: mouseDownPoint)                       // the word under the press
}

func lookUp(at pagePoint: CGPoint) {
    let word = geometry.wordIndex(at: pagePoint).map { geometry.words[$0] }
    let baseline = CGPoint(x: word.bbox.midX * zoom, y: word.baselineY * zoom)
    showDefinition(for: NSAttributedString(string: word.text), at: baseline)
}
```

`showDefinition(for:at:)` is the public AppKit API that opens the same dictionary panel as
Preview and Books. The three-finger tap / "Look Up" system gesture and the `⌘D` item use the
same code path.

When the right click lands inside a selection, the dictionary opens for the word taken from the
selection (the same thesaurus Preview shows), not for whatever pixel happens to be under the cursor.

---

## Speech and translation

Both actions are available from the page context menu, from the `Озвучка` / `Перевод` menus and on
shortcuts: `⌥⎋` reads the selection, `⌥⌘T` translates it.

![Translation panel](docs/translation-panel.png)

The panel shows the source text, the translation and the current language pair. Changing the pair
re-translates the same fragment immediately and is stored in `UserDefaults`
(`Folio.translate.source`, `Folio.translate.target`), so the choice survives relaunches; the factory
default is **English (US) → Russian** and can be restored with one button. Translation runs on
device through the system Translation framework (`TranslationSession` handed out by SwiftUI's
`.translationTask`), so the first use of a pair may download language models — macOS 15 or newer is
required, and the menu items are disabled on older systems.

![Settings](docs/settings.png)

Speech uses `AVSpeechSynthesizer`, with the voice matched to the language of the text
(`NLLanguageRecognizer`, falling back to the system locale). **Speech is disabled by default**: until
it is enabled in Settings the menu items stay visible but disabled and explain where to turn it on,
so a stray shortcut never starts reading in a library.

---

## Quick start

Requirements: macOS 14+, Xcode 16+ (verified on macOS 27.2 / Xcode 27.2, arm64) and a Rust
toolchain (`rustup`, 1.92+).

```bash
# 1. PDFium (prebuilt, BSD-3)
./scripts/download-pdfium.sh

# 2. Rust core: cargo build --release, then copy + sign the dylib for the app
./scripts/build-core.sh

# 3. Test fixtures (attention.pdf is not committed)
./scripts/fetch-samples.sh

# 4. Run the app
./scripts/run-app.sh samples/attention.pdf
```

If your Rust toolchain lives in a local directory (as in the original development workspace),
put it in `../.toolchain` next to the repository — the scripts pick it up automatically;
otherwise the system `cargo`/`rustc` from `PATH` is used.

The SwiftPM package builds with `swift build` in `app/`. Note: inside some sandboxed
environments SwiftPM needs `--disable-sandbox`; the provided scripts already pass it.

Test documents:

| File | Purpose |
|---|---|
| `samples/attention.pdf` | 15 pages, LaTeX, untagged: 1–3 level headings, headers/footers, captions (downloaded by `scripts/fetch-samples.sh`) |
| `samples/sample-ru.pdf` | 3 pages, Cyrillic: headings, list, caption, code block, running headers |
| `samples/no-text.pdf` | page without a text layer (0 headings, dictionary reports it gracefully) |

### Build a real `.app`

```bash
./scripts/build-app.sh            # release build + icon + signature → dist/Folio.app
open dist/Folio.app
open dist/Folio.app --args samples/attention.pdf
```

Bundle layout:

```
dist/Folio.app/Contents/
├── Info.plist            CFBundleIdentifier dev.folio.reader,
│                         CFBundleDocumentTypes → com.adobe.pdf (Open With → Folio)
├── MacOS/Folio           release binary (SwiftUI + AppKit)
├── Frameworks/
│   ├── libpdfcore.dylib  Rust core
│   └── libpdfium.dylib   PDFium
├── Resources/AppIcon.icns
└── PkgInfo
```

- The app looks for the core inside its own bundle first (`Contents/Frameworks`) and only then
  in the development tree, so double-clicking from Finder uses the embedded dylibs.
- The bundle is **ad-hoc signed** (`codesign --sign -`), which is required on arm64. On
  another Mac Gatekeeper will block it: right-click → Open, or System Settings → Privacy &
  Security → "Open Anyway". Distribution requires a Developer ID certificate and notarization
  (`codesign --options runtime`, `notarytool`, `stapler`).
- `dist/Folio.app.zip` is a clean archive (no extended attributes) suitable for moving to
  another Mac. In a file-provider-synced folder macOS re-adds `com.apple.FinderInfo` to the
  bundle, so `codesign --verify --deep --strict` on that copy may complain — it does not affect
  the signature validity or launching (verified).
- `build-app.sh` registers the bundle in LaunchServices (`lsregister`), so PDFs can be opened
  via "Open With → Folio"; Finder passes the file through
  `application(_:open:)` → `ReaderModel.openFromFinder`.

Icons are generated by [`scripts/make-icon.swift`](scripts/make-icon.swift).

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘O` | open a PDF in the current window |
| `⌘N` | new window (its own document) |
| `⌘+` / `⌘−` / `⌘1` / `⌘0` | zoom / actual size / fit width |
| `⌘D` | look up in the dictionary (selection → hover → first word) |
| `⌥⌘T` | translate the selection (system Translation, EN US → RU by default) |
| `⌥⎋` | read the selection aloud (after speech is enabled in Settings) |
| `⌘,` | settings: speech on/off, speed, translation languages |
| `⌘C` / `⇧⌘C` | copy selection / copy selected text (menu item) |
| `⌘F` | search in the document |
| `⌘↑` / `⌘↓` | previous / next page |
| `⇧⌘D` / `⇧⌘W` | element layout / word boxes |
| `⇧⌘E` | export document structure to JSON |
| double-click a PDF in Finder | open in Folio (after bundle registration) |

### Headless snapshot mode

Used for automated acceptance (no Screen Recording permission required):

```bash
./app/.build/debug/Folio --snapshot /tmp/snap samples/attention.pdf
# → root.png, debug.png, debug-words.png, search.png, thumbnails.png, scroll.png,
#   dark.png, selection.png, sidebar-hidden.png, settings.png, translation-panel.png,
#   summary.txt; exit code 0
```

Two optional flags exercise the new features for real instead of rendering placeholder state:
`--snapshot-translate` translates the selected text through the system Translation framework
(requires downloaded language models), `--snapshot-speech` actually speaks the selection through
`AVSpeechSynthesizer`. Without them the run only proves the guards: speech stays silent while the
setting is off, and the panel is filled with demo text.

---

## Testing & verification

- [`scripts/accept-core.py`](scripts/accept-core.py) — an independent core acceptance suite that
  loads the dylib through `ctypes` (the same path the Swift bridge uses) and validates the C ABI,
  JSON schemas, bboxes, reading order, heading levels, header/footer filtering, render
  background/orientation, alpha, search, and error handling on broken files:
  **86/86 checks, both languages**.
- `cargo test` — unit tests for grouping plus integration tests on real PDFs (28 tests).
- The app: snapshots of `attention.pdf` at 100/150/200%, Cyrillic document, `no-text.pdf`,
  document switching (cache invalidation), dictionary path and `⌘C` — verified via logs.
- Windows and session restore, verified against the signed `.app` through LaunchServices
  (`open -a dist/Folio.app [file.pdf]`, window list checked with `CGWindowListCopyWindowInfo`
  and an in-app report enabled by `defaults write dev.folio.reader Folio.windowReport -bool YES`):
  a cold start with a document yields **one** window, opening two more PDFs yields **three**
  windows holding *different* documents, and a plain relaunch restores the last book on the page
  it was left (`--goto-page` equivalent via `Folio.debugGotoPage` + graceful quit). SwiftUI's
  own window for an open event and macOS window restoration are cleaned up by
  [WindowHygiene.swift](app/Sources/Folio/App/WindowHygiene.swift).
- Settings and translation contract, verified in the same headless run: speech is **off** by
  default, the language pair defaults to **EN (US) → RU**, a user-chosen pair and speed survive a
  simulated relaunch (throwaway `UserDefaults` suite — the developer's real preferences are not
  touched), `speak()` refuses to run while the toggle is off, and the page context menu is dumped
  and checked for the dictionary, translate, speak and settings items (with different titles for a
  selection and for a bare word).
- The `.app` bundle: launching from `dist/Folio.app` (including with cwd `/`, like Finder) uses
  the embedded dylibs from `Contents/Frameworks`; opening a PDF through LaunchServices loads
  the document (verified via the persisted `lastDocumentPath`); `codesign --verify --deep
  --strict` passes on the archive staging copy and on the unzipped bundle.

> Note: the system dictionary panel cannot be screenshotted in a headless environment (no
> Screen Recording permission), so automation verifies the `showDefinition(for:at:)` call and
> the baseline point via logs. The actual stage-2 pressure events can only be felt on a real
> Force Touch trackpad.

### `pc-cli` (core debugging tool)

```bash
cd core
./target/release/pc-cli info      ../samples/attention.pdf
./target/release/pc-cli structure ../samples/sample-ru.pdf
./target/release/pc-cli blocks    ../samples/attention.pdf --page 0
./target/release/pc-cli text      ../samples/attention.pdf --page 0 --pretty
./target/release/pc-cli render    ../samples/attention.pdf --page 0 --scale 2 --out /tmp/page.ppm
./target/release/pc-cli search    ../samples/attention.pdf attention
./target/release/pc-cli bench     ../samples/attention.pdf
```

---

## Project layout

```
.
├── CONTRACT.md                  core ↔ app contract (C ABI, JSON, acceptance criteria)
├── LICENSE
├── core/                        Rust core (PDFium)
│   ├── src/{ffi,text,classify,structure,json_types,api,ffi_api,lib}.rs
│   ├── src/bin/pc-cli.rs        CLI: info/text/structure/blocks/render/search/bench
│   ├── include/pdfcore.h        C ABI header
│   ├── tests/integration.rs
│   └── vendor/pdfium/           libpdfium.dylib + headers (downloaded, not committed)
├── app/                         SwiftPM app (SwiftUI + AppKit)
│   ├── Package.swift
│   ├── Bundle/Info.plist
│   └── Sources/Folio/
│       ├── App/         FolioApp (menus, ⌘C/⌘D monitors), ReaderScene, WindowRouter,
│       │                WindowHygiene, SnapshotRunner, WindowReport, AppDebugHooks
│       ├── Model/       ReaderModel (one per window), ReadingPositionStore, SettingsStore,
│       │                SpeechService, TranslationController, ReaderFocus
│       ├── UI/          RootView, page canvas, sidebars, SettingsView,
│       │                TranslationPanel, TranslationTaskHost
│       └── Core/        PdfCoreBridge (dlopen + C ABI), JSON models
├── scripts/                     download-pdfium, build-core, run-app, build-app,
│                                make-icon, fetch-samples, accept-core, make-sample-ru
├── samples/                     sample-ru.pdf, no-text.pdf (+ attention.pdf fetched)
├── docs/                        screenshots and icon
└── dist/                        built Folio.app (+ zip), not committed
```

---

## Limitations & roadmap

Current limitations:

- no annotations, forms, links, printing; PDF bookmarks are only used as a level source;
- selection is limited to a single page; no cross-page selection;
- complex scripts (RTL, vertical text) and scans without a text layer are out of scope (no OCR);
- the app is built as a SwiftPM executable and a minimal `.app` bundle: no Developer ID
  signature or notarization, no App Sandbox;
- render cache is bounded by size; very heavy pages are not optimized;
- stage-2 force click requires a Force Touch trackpad; `⌘D` is the fallback;
- translation needs macOS 15+ and the language models installed by the system: the first use of a
  pair can take minutes while the models download (progress is shown by the framework);
- speech uses the system voices; it is off by default and only reads the selection/word, not a
  whole page;
- zooming beyond fit-width shows a horizontal scrollbar (no auto-centering);
- the UI is in Russian (localization is not implemented yet).

Natural next steps on top of the current architecture:

- links and annotations (`FPDFLink_*`, `FPDFAnnot_*`);
- proper document-based app (`NSDocument` / `DocumentGroup`) with recent documents and
  per-window session restore (reading position is already persisted);
- incremental rendering and neighbor-page preloading;
- tagged PDF → semantic tree (currently only H1–H6 + outlines);
- English UI + localization via String Catalogs;
- translating whole blocks/pages in one batch (`translations(from:)`) and caching the results;
- Developer ID signing, notarization and a DMG.

---

## License & acknowledgements

- Code: **MIT** (see [`LICENSE`](LICENSE)).
- **PDFium** — BSD-3-Clause, Copyright The PDFium Authors (Chromium project). Prebuilt macOS
  binaries come from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries);
  the license texts are shipped inside the downloaded archive.
- Rust dependencies: `libloading` (ISC), `serde` / `serde_json` (MIT/Apache-2.0),
  `once_cell` (MIT/Apache-2.0).
- The test paper "Attention Is All You Need" (Vaswani et al., arXiv:1706.03762) is downloaded
  locally by `scripts/fetch-samples.sh` and is not part of this repository.
