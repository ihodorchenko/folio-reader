#!/bin/bash
# Builds the real Folio.app (release): bundle, icon, embedded dylibs.
# Signs ad-hoc by default; set FOLIO_SIGN_IDENTITY (and FOLIO_NOTARIZE=1) for a
# Developer ID signature with notarization — see README "Signing and notarization".
# The build and signing happen in a temporary directory (outside the synchronized workspace
# folder); the result is then copied to dist/ and packed into a clean zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$(cd "$ROOT/.." && pwd)/.toolchain"
DIST="$ROOT/dist"
APP="$DIST/Folio.app"
ZIP="$DIST/Folio.app.zip"
# Version and build number come from the Xcode project — the single source of truth
# (MARKETING_VERSION / CURRENT_PROJECT_VERSION); app/Bundle/Info.plist only carries the
# $(…) placeholders, so a second copy of the version does not exist. FOLIO_VERSION / FOLIO_BUILD
# still win, so CI can stamp its own build number (github.run_number).
PROJECT="$ROOT/Folio.xcodeproj/project.xcproj"

# Build setting from the project file. It is JSON with trailing commas, which a strict JSON
# parser rejects, so the value is taken with a targeted regex (as in scripts/set-version.sh).
project_setting() {
    python3 - "$PROJECT" "$1" 2>/dev/null <<'PY' || true
import re, sys
path, key = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    raise SystemExit(0)
match = re.search(r'"%s"\s*:\s*"([^"]*)"' % re.escape(key), text)
if match:
    print(match.group(1))
PY
}

VERSION="${FOLIO_VERSION:-$(project_setting MARKETING_VERSION)}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${FOLIO_BUILD:-$(project_setting CURRENT_PROJECT_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${FOLIO_BUNDLE_ID:-dev.folio.reader}"

echo "Folio $VERSION ($BUILD_NUMBER)"

# Signing and notarization (all optional; "-" keeps the current ad-hoc signature).
#   FOLIO_SIGN_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   FOLIO_NOTARIZE=1     submit to Apple and staple the ticket (needs one credential set below)
#   FOLIO_NOTARY_PROFILE     notarytool keychain profile (xcrun notarytool store-credentials)
#   or FOLIO_NOTARY_KEY_PATH/FOLIO_NOTARY_KEY_ID/FOLIO_NOTARY_ISSUER (App Store Connect API key)
#   or FOLIO_NOTARY_APPLE_ID/FOLIO_NOTARY_TEAM_ID/FOLIO_NOTARY_PASSWORD (app-specific password)
SIGN_IDENTITY="${FOLIO_SIGN_IDENTITY:--}"
NOTARIZE="${FOLIO_NOTARIZE:-0}"
NOTARY_PROFILE="${FOLIO_NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${FOLIO_NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${FOLIO_NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${FOLIO_NOTARY_PASSWORD:-}"
NOTARY_KEY_PATH="${FOLIO_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${FOLIO_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${FOLIO_NOTARY_ISSUER:-}"

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

echo "== 1/8 PDFium =="
[ -f "$ROOT/core/vendor/pdfium/libpdfium.dylib" ] || "$ROOT/scripts/download-pdfium.sh"

echo "== 2/8 Rust core (release) =="
( cd "$ROOT/core" && cargo build --release )
[ -f "$ROOT/core/target/release/libpdfcore.dylib" ] || { echo "libpdfcore.dylib is missing"; exit 1; }

echo "== 3/8 Swift app (release) =="
( cd "$ROOT/app" && swift build --disable-sandbox -c release )
BIN="$ROOT/app/.build/release/Folio"
[ -x "$BIN" ] || { echo "binary is missing: $BIN"; exit 1; }

echo "== 4/8 icon =="
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

echo "== 5/8 bundle assembly =="
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

echo "== 6/8 signing and verification =="
xattr -cr "$STAGE" 2>/dev/null || true
SIGN_ARGS=(--force --sign - --timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
  # Distribution signing: hardened runtime is mandatory for notarization, timestamps too.
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
codesign "${SIGN_ARGS[@]}" "$STAGE/Contents/Frameworks/libpdfium.dylib"
codesign "${SIGN_ARGS[@]}" "$STAGE/Contents/Frameworks/libpdfcore.dylib"
codesign "${SIGN_ARGS[@]}" "$STAGE"
codesign --verify --deep --strict --verbose=2 "$STAGE" 2>&1 | tail -2
if [ "$SIGN_IDENTITY" = "-" ]; then
  SIGNING_SUMMARY="ad-hoc (arm64 requires at least an ad-hoc signature)"
else
  SIGNING_SUMMARY="$SIGN_IDENTITY (hardened runtime)"
fi
echo "signature: $SIGNING_SUMMARY"

echo "== 7/8 notarization =="
if [ "$NOTARIZE" = "1" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "ERROR: notarization needs a Developer ID signature — set FOLIO_SIGN_IDENTITY" >&2
    exit 1
  fi
  NOTARY_ZIP="$STAGE_ROOT/Folio-notarization.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$NOTARY_ZIP"
  if [ -n "$NOTARY_PROFILE" ]; then
    SUBMIT=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "$NOTARY_KEY_PATH" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
    SUBMIT=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  elif [ -n "$NOTARY_APPLE_ID" ] && [ -n "$NOTARY_TEAM_ID" ] && [ -n "$NOTARY_PASSWORD" ]; then
    SUBMIT=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
  else
    echo "ERROR: notarization requested but no credentials — set FOLIO_NOTARY_PROFILE or the Apple ID / API key variables" >&2
    exit 1
  fi
  echo "submitting to the Apple notary service (this can take a few minutes)…"
  if ! xcrun notarytool submit "$NOTARY_ZIP" "${SUBMIT[@]}" --wait; then
    echo "ERROR: notarization failed — inspect the log with 'xcrun notarytool log <id> …'" >&2
    exit 1
  fi
  xcrun stapler staple "$STAGE"
  xcrun stapler validate "$STAGE"
  SIGNING_SUMMARY="$SIGNING_SUMMARY, notarized and stapled"
  echo "signature: $SIGNING_SUMMARY"
else
  echo "notarization skipped (set FOLIO_NOTARIZE=1 with a Developer ID signature to enable it)"
fi

echo "== 8/8 dist/ and a clean zip =="
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
echo "Signature: $SIGNING_SUMMARY"
echo "Launch:   open \"$APP\""
echo "With PDF: open \"$APP\" --args \"$ROOT/samples/attention.pdf\""
