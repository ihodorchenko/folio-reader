# pdfcore — the Folio Rust core

PDF rendering (PDFium), extraction of words/lines/blocks with typography, element
classification, document-wide heading levels, outline/tagged structure tree, search, and the
C ABI for the macOS app. The single source of truth is [`../CONTRACT.md`](../CONTRACT.md).

## Building

```bash
export REPO_ROOT="$PWD"                  # repository root
export RUSTUP_HOME="$REPO_ROOT/../.toolchain/rustup"
export CARGO_HOME="$REPO_ROOT/../.toolchain/cargo"
export PATH="$CARGO_HOME/bin:$PATH"
cd core
cargo build --release        # target/release/libpdfcore.dylib + libpdfcore.a + pc-cli
cargo test                   # unit tests + integration tests on ../samples/*.pdf
```

The toolchain lives in a workspace-local `.toolchain` directory next to the checkout; with a
stock rustup installation, skip the `RUSTUP_HOME`/`CARGO_HOME` exports.

PDFium is loaded at runtime (`dlopen`) from `vendor/pdfium/libpdfium.dylib`.
Lookup order: the `PDFIUM_DYLIB` env var → next to `libpdfcore.dylib` itself →
next to the executable → `$FOLIO_ROOT/core/vendor/pdfium` → `vendor/pdfium`
relative to the current directory (up to 5 levels) → the path compiled in from
`CARGO_MANIFEST_DIR` (for `cargo test`/`pc-cli`).

## Modules

| file | purpose |
|---|---|
| `src/ffi.rs` | FFI declarations matching `vendor/pdfium/fpdf*.h`, the dylib loader, the global PDFium mutex |
| `src/text.rs` | characters → words → lines → blocks; top-left coordinates with `/Rotate` applied; hyphen joining; detection of vertically mirrored PDFs |
| `src/classify.rs` | kind heuristics (heading/list/caption/code/formula/header/footer/reference/quote), confidence |
| `src/structure.rs` | outline from bookmarks, structure tree (H1..H6), document-wide level clustering, title, search, junk-heading rejection |
| `src/json_types.rs` | serde models matching CONTRACT §3–§5 exactly (camelCase, `bbox:{x,y,w,h}`, no NaN) |
| `src/api.rs` | safe API: opening, layout/structure JSON cache, BGRA rendering |
| `src/ffi_api.rs` | C ABI (`catch_unwind`, thread-local `last_error`, malloc buffers) |
| `src/bin/pc-cli.rs` | debugging CLI (see below) |

## C ABI

`include/pdfcore.h` matches contract §1 exactly. Check:
`clang -fsyntax-only -I include include/pdfcore.h`.

## pc-cli

```bash
./target/release/pc-cli info ../samples/attention.pdf
./target/release/pc-cli structure ../samples/attention.pdf
./target/release/pc-cli blocks ../samples/attention.pdf --page 0
./target/release/pc-cli text ../samples/attention.pdf --page 0 --pretty
./target/release/pc-cli render ../samples/attention.pdf --page 0 --scale 2 --out /tmp/page.ppm
./target/release/pc-cli search ../samples/attention.pdf attention
./target/release/pc-cli bench ../samples/attention.pdf
./target/release/pc-cli fonts ../samples/attention.pdf   # font debugging
./target/release/pc-cli rawchars ../samples/attention.pdf --page 0 --limit 50
```

`render` writes PPM (P6); for PNG: `sips -s format png /tmp/page.ppm --out /tmp/page.png`.

## Implementation notes

* **PDFium is not thread-safe** — every call goes through a single global `Mutex`;
  a document can be passed freely between threads.
* **Font size**: `FPDFText_GetFontSize` ignores the text matrix scale (Quartz/
  macOS print-to-PDF writes `Tf=1`), so the effective size is
  `GetFontSize × |matrix|` from `FPDFText_GetMatrix`.
* **Vertically mirrored PDFs** (negative `d` in the text matrix) are detected from the
  position of the first character on the page: coordinates are normalized to the "visual"
  space and the raster is flipped row by row, so the text and the image match.
* **Words**: boundaries are real whitespace characters and PDFium-generated spaces (their
  position is unreliable, their order in the stream is reliable), plus gaps >0.24 em; a
  trailing hyphen is joined in the block text.
* **Columns**: a row is split into fragments at gaps >1.7 em, so the left and right columns
  do not get merged.
* **Heading levels**: numbered headings use number depth (1 → L1, 3.2.1 → L3), unnumbered
  ones use the document-wide (size, bold) cluster; Abstract/References are recognized by
  their typical names.
* **Junk headings are filtered out**: duplicates, text with a low letter ratio, run-together
  text, a size < body×1.05 without numbering, unnumbered "headings" after References, and
  single footnote characters as blocks.
