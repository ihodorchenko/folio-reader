#!/bin/bash
# Builds the app and launches it with the given PDF (or with the demo document).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FOLIO_ROOT="$ROOT"
export PDFCORE_DYLIB="$ROOT/app/.build/core/libpdfcore.dylib"

DEFAULT_PDF="$ROOT/samples/attention.pdf"
[ -f "$DEFAULT_PDF" ] || DEFAULT_PDF="$ROOT/samples/sample-ru.pdf"

cd "$ROOT/app"
swift build --disable-sandbox "$@"
exec "$ROOT/app/.build/debug/Folio" "${FOLIO_PDF:-$DEFAULT_PDF}"
