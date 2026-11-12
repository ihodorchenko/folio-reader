# Folio {{VERSION}}

A native macOS PDF reader with a **Rust/PDFium** rendering core, recovered document structure and
the system thesaurus on a force click — in the spirit of Preview and Books.

![Folio](https://raw.githubusercontent.com/ihodorchenko/folio-reader/main/docs/root.png)

<!--
Manual release-notes template. Copy it, replace {{VERSION}}, {{SHA256}} and {{COMMIT}}, add the
"What's new" section and publish the release by hand (see docs/releasing.md). There is no automated
release workflow.
-->

## What's new in {{VERSION}}

- _Add the changelog for this version here before publishing._

## Highlights

- **Rust core over PDFium** — per-character boxes, effective font size, bookmarks and tagged-PDF
  structure; headings H1–H6 with `confidence` and source (`heuristic` / `tagged` / `outline`);
  11 element kinds (body, list, caption, table, code, header/footer, formula, quote, reference…).
- **Force click → system thesaurus/dictionary** (`NSView.showDefinition(for:at:)`), also `⌘D` and the
  page context menu; one gesture opens the panel exactly once.
- **Read aloud** — the selection through `AVSpeechSynthesizer`; off by default, toggle/rate/voice in
  Settings, `⌥⎋`.
- **Translation** — the selection through the system Translation framework (`⌥⌘T`); default pair
  English (US) → Russian, a chosen pair is remembered between launches.
- **One window per book** — opening a PDF from Finder or `⌘N` creates an independent window; a cold
  start shows exactly one window, and the last document reopens on the remembered page, scroll and zoom.
- **Open Recent** in the File menu and the toolbar, with an MRU list and “Clear Menu”.
- **Bilingual UI (English and Russian)** that follows the system language; code, comments and
  documentation are English.

| Translation (English UI) | Settings (Russian UI) |
|---|---|
| ![Translation](https://raw.githubusercontent.com/ihodorchenko/folio-reader/main/docs/translation-panel.png) | ![Settings](https://raw.githubusercontent.com/ihodorchenko/folio-reader/main/docs/settings-ru.png) |

## Install

1. Unzip `Folio.app.zip` and move `Folio.app` to `/Applications`.
2. The bundle is **signed with a Developer ID and notarized by Apple** — it opens with a normal
   double click, no Gatekeeper bypass is needed.
3. Open PDFs with **Open With → Folio**, by dragging them into the window, or with `⌘O`.

**Requires macOS 14+ and an arm64 Mac** (Apple Silicon). The archive is a thin arm64 build.

## Verification

- CI (macOS 15, Swift 6.0): Rust unit + integration tests, core acceptance (**86/86**) and the app
  build are green for this commit.
- The release bundle is built and notarized locally in Xcode; it is re-checked with
  `codesign --verify --deep --strict`, `spctl --assess` and `xcrun stapler validate`, and the
  attached SHA-256 is computed from the published zip.

## Known limitations

- no annotations, forms, links or printing; PDF bookmarks are only used as a heading source;
- selection is limited to a single page; scans without a text layer are out of scope (no OCR);
- translation needs macOS 15+ and the system language models; speech depends on system voices;
- the mock demo document (shown when the core is not built) is English-only data.

**SHA-256** `Folio.app.zip`: `{{SHA256}}`

Built from [`{{COMMIT}}`](https://github.com/ihodorchenko/folio-reader/commit/{{COMMIT}}).
