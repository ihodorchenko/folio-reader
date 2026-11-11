#!/bin/bash
# Builds the real Folio.app (release): bundle, icon, embedded dylibs, ad-hoc signature.
# The build and signing happen in a temporary directory (outside the synchronized workspace
# folder); the result is then copied to dist/ and packed into a clean zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$(cd "$ROOT/.." && pwd)/.toolchain"
DIST="$ROOT/dist"
APP="$DIST/Folio.app"
ZIP="$DIST/Folio.app.zip"
# Version defaults to the Info.plist template; CI overrides it from the git tag.
VERSION="${FOLIO_VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/app/Bundle/Info.plist" 2>/dev/null || echo 1.0)}"
BUILD_NUMBER="${FOLIO_BUILD:-1}"
BUNDLE_ID="${FOLIO_BUNDLE_ID:-dev.folio.reader}"

# Optional project-local toolchain; otherwise use cargo/rustc from PATH.
if [ -d "$TOOLCHAIN/cargo" ] && [ -d "$TOOLCHAIN/rustup" ]; then
  export RUSTUP_HOME="$TOOLCHAIN/rustup"
  export CARGO_HOME="$TOOLCHAIN/cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
command -v cargo >/dev/null 2>&1 || {
  echo "cargo not found: install Rust from https://rustup.rs" >&2
  exit 1
}

STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/folio-build.XXXXXX")"
STAGE="$STAGE_ROOT/Folio.app"
trap 'rm -rf "$STAGE_ROOT"' EXIT

echo "== 1/7 PDFium =="
[ -f "$ROOT/core/vendor/pdfium/libpdfium.dylib" ] || "$ROOT/scripts/download-pdfium.sh"

echo "== 2/7 Rust core (release) =="
( cd "$ROOT/core" && cargo build --release )
[ -f "$ROOT/core/target/release/libpdfcore.dylib" ] || { echo "libpdfcore.dylib is missing"; exit 1; }

echo "== 3/7 Swift app (release) =="
( cd "$ROOT/app" && swift build --disable-sandbox -c release )
BIN="$ROOT/app/.build/release/Folio"
[ -x "$BIN" ] || { echo "binary is missing: $BIN"; exit 1; }

echo "== 4/7 icon =="
ICON_PNG="$ROOT/app/.build/AppIcon-1024.png"
ICONSET="$ROOT/app/.build/AppIcon.iconset"
rm -rf "$ICONSET" "$ICON_PNG"
CLANG_MODULE_CACHE_PATH="$ROOT/app/.build/iconcache" \
  swift -module-cache-path "$ROOT/app/.build/iconcache" "$ROOT/scripts/make-icon.swift" "$ICON_PNG"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$ICON_PNG" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/app/.build/AppIcon.icns"

echo "== 5/7 bundle assembly =="
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Frameworks" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Folio"
cp "$ROOT/core/target/release/libpdfcore.dylib" "$STAGE/Contents/Frameworks/"
cp "$ROOT/core/vendor/pdfium/libpdfium.dylib" "$STAGE/Contents/Frameworks/"
cp "$ROOT/app/.build/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
# UI localizations (English is the source language, Russian is in ru.lproj).
if [ -d "$ROOT/app/Resources" ]; then
  for lproj in "$ROOT/app/Resources"/*.lproj; do
    [ -d "$lproj" ] && ditto "$lproj" "$STAGE/Contents/Resources/$(basename "$lproj")"
  done
fi
cp "$ROOT/app/Bundle/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$STAGE/Contents/Info.plist"

echo "== 6/7 signing and verification (ad-hoc; required on arm64) =="
xattr -cr "$STAGE" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$STAGE/Contents/Frameworks/libpdfium.dylib"
codesign --force --sign - --timestamp=none "$STAGE/Contents/Frameworks/libpdfcore.dylib"
codesign --force --sign - --timestamp=none "$STAGE"
codesign --verify --deep --strict --verbose=2 "$STAGE" 2>&1 | tail -2

echo "== 7/7 dist/ and a clean zip =="
mkdir -p "$DIST"
rm -rf "$APP" "$ZIP"
# Copy without xattr; macOS may re-add FinderInfo (synchronized folder), which does not
# affect launching. The reference signature was verified on $STAGE above.
ditto --norsrc --noextattr "$STAGE" "$APP"
xattr -cr "$APP" 2>/dev/null || true
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"

# Register with LaunchServices so "Open With → Folio" works.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo
echo "Done:"
printf '  %s  (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)"
printf '  %s  (%s)\n' "$ZIP" "$(du -sh "$ZIP" | cut -f1)"
echo "Launch:   open \"$APP\""
echo "With PDF: open \"$APP\" --args \"$ROOT/samples/attention.pdf\""
