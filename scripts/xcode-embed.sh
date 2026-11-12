#!/bin/bash
# Xcode Run Script phase: builds the Rust core, renders the app icon and embeds
# the dylibs and localizations into Xcode's product bundle.
#
# Runs inside an Xcode build; the environment provides BUILT_PRODUCTS_DIR,
# FRAMEWORKS_FOLDER_PATH, UNLOCALIZED_RESOURCES_FOLDER_PATH and
# EXPANDED_CODE_SIGN_IDENTITY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building the Rust core…"
"$ROOT/scripts/build-core.sh" >/dev/null

[ -f "$ROOT/core/vendor/pdfium/libpdfium.dylib" ] || "$ROOT/scripts/download-pdfium.sh"

echo "Rendering the app icon…"
ICON_PNG="${TMPDIR:-/tmp}/folio-icon-1024.png"
ICONSET="${TMPDIR:-/tmp}/folio-icon.iconset"
rm -rf "$ICON_PNG" "$ICONSET"
CLANG_MODULE_CACHE_PATH="$ROOT/app/.build/iconcache" \
    swift -module-cache-path "$ROOT/app/.build/iconcache" \
    "$ROOT/scripts/make-icon.swift" "$ICON_PNG"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$ICON_PNG" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/app/.build/AppIcon.icns"

FRAMEWORKS="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
RESOURCES="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "$FRAMEWORKS" "$RESOURCES"

cp "$ROOT/core/target/release/libpdfcore.dylib" "$FRAMEWORKS/"
cp "$ROOT/core/vendor/pdfium/libpdfium.dylib" "$FRAMEWORKS/"
cp "$ROOT/app/.build/AppIcon.icns" "$RESOURCES/AppIcon.icns"
ditto "$ROOT/app/Resources/ru.lproj" "$RESOURCES/ru.lproj"

IDENT="${EXPANDED_CODE_SIGN_IDENTITY:-}"
for lib in "$FRAMEWORKS"/*.dylib; do
    if [ -n "$IDENT" ] && [ "$IDENT" != "-" ]; then
        codesign --force --options runtime --timestamp --sign "$IDENT" "$lib"
    else
        codesign --force --sign - "$lib"
    fi
done

echo "Embedded: $(basename "$FRAMEWORKS")/*.dylib, AppIcon.icns, ru.lproj"
