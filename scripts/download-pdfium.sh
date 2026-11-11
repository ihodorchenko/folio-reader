#!/bin/bash
# Downloads the prebuilt PDFium (BSD-3) for macOS (arm64 or x64).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/core/vendor/pdfium"
TAG="${PDFIUM_TAG:-chromium/8152}"
ARCH="${PDFIUM_ARCH:-}"
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    arm64)  ARCH="mac-arm64" ;;
    x86_64) ARCH="mac-x64" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi

if [ -f "$DEST/libpdfium.dylib" ]; then
  echo "PDFium is already in place: $DEST/libpdfium.dylib"
  exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
# The tag contains a slash (e.g. chromium/8152), which must be percent-encoded.
ENCODED_TAG="${TAG//\//%2F}"
URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${ENCODED_TAG}/pdfium-${ARCH}.tgz"
echo "Downloading $URL"
curl -sSL -o "$TMP/pdfium.tgz" "$URL"
tar xzf "$TMP/pdfium.tgz" -C "$DEST" --strip-components=1
rm -rf "$TMP"
ls -lh "$DEST/libpdfium.dylib"
