#!/bin/bash
# Packages the notarized app that Xcode exported into the release asset: zip + SHA-256, and
# verifies exactly what a user will download.
#
#   ./scripts/package-release.sh                       # project version, dist/Folio.app → dist/
#   ./scripts/package-release.sh 1.2.2                 # explicit version
#   FOLIO_APP=~/Desktop/Folio.app FOLIO_OUT=~/Desktop ./scripts/package-release.sh
#
# Notarization happens only in Xcode (Organizer → Distribute App → Developer ID): the Developer ID
# identity and the notary credentials live in the Xcode session, so the terminal has neither. A
# bundle from scripts/build-app.sh is ad-hoc signed — this script refuses to package it, because
# such a zip cannot be distributed (Gatekeeper rejects it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Folio.xcodeproj/project.xcproj"
APP="${FOLIO_APP:-$ROOT/dist/Folio.app}"
OUT="${FOLIO_OUT:-$ROOT/dist}"
ZIP="$OUT/Folio.app.zip"
CHECKSUM="$OUT/Folio.app.zip.sha256"

project_value() {
    python3 - "$PROJECT" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r'"%s"\s*:\s*"([^"]*)"' % re.escape(sys.argv[2]), text)
if not match:
    raise SystemExit(f"error: {sys.argv[2]} is missing from {sys.argv[1]}")
print(match.group(1))
PY
}

VERSION="${1:-$(project_value MARKETING_VERSION)}"
BUILD="$(project_value CURRENT_PROJECT_VERSION)"

echo "== 1/3 the bundle =="
if [ ! -d "$APP" ]; then
    echo "error: $APP not found — archive and notarize in Xcode, then export the app there" >&2
    exit 1
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
if [ "$APP_VERSION" != "$VERSION" ]; then
    echo "error: $APP is $APP_VERSION, expected $VERSION — export the current build from Xcode" >&2
    exit 1
fi
if [ "$APP_BUILD" != "$BUILD" ]; then
    echo "error: build number mismatch: the app is $APP_BUILD, the project is $BUILD" >&2
    echo "       (a stale export or a forgotten scripts/set-version.sh run)" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || {
    echo "error: $APP does not pass 'codesign --verify --deep --strict'" >&2
    exit 1
}
# Read the whole codesign output: an early `exit` in awk would SIGPIPE codesign and, with
# `set -o pipefail`, abort the script (141) before any check runs.
AUTHORITY="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F'=' '/^Authority=Developer ID Application/ {found=$2} END {print found}')"
if [ -z "$AUTHORITY" ]; then
    echo "error: $APP is not signed with a Developer ID Application certificate" >&2
    echo "       scripts/build-app.sh produces an ad-hoc bundle — it is never a release asset" >&2
    codesign -dv --verbose=4 "$APP" 2>&1 | grep -E '^Authority=' >&2 || true
    exit 1
fi
SPCTL="$(spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true)"
case "$SPCTL" in
    *"source=Notarized Developer ID"*) ;;
    *)
        echo "error: Gatekeeper does not accept $APP as notarized:" >&2
        echo "       ${SPCTL:-no verdict}" >&2
        exit 1
        ;;
esac
echo "  $APP — $VERSION ($BUILD), $AUTHORITY, notarized"
echo "$SPCTL" | sed 's/^/  /'

echo "== 2/3 the archive =="
mkdir -p "$OUT"
rm -f "$ZIP" "$CHECKSUM"
# ditto keeps resource forks and extended attributes: the stapled ticket must survive the zip.
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$CHECKSUM"
cat "$CHECKSUM" | sed 's/^/  /'

echo "== 3/3 the downloaded artifact =="
TMP="$(mktemp -d "${TMPDIR:-/tmp}/folio-release.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
UNPACKED="$TMP/$(basename "$APP")"
if [ ! -d "$UNPACKED" ]; then
    echo "error: the zip does not contain $(basename "$APP")" >&2
    exit 1
fi
UNPACKED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$UNPACKED/Contents/Info.plist")"
if [ "$UNPACKED_VERSION" != "$VERSION" ]; then
    echo "error: the unpacked app reports $UNPACKED_VERSION, expected $VERSION" >&2
    exit 1
fi
if ! spctl --assess --type execute "$UNPACKED" >/dev/null 2>&1; then
    echo "error: the unpacked app is rejected by Gatekeeper" >&2
    exit 1
fi
if ! xcrun stapler validate "$UNPACKED" >/dev/null 2>&1; then
    echo "error: the notarization ticket did not survive packaging" >&2
    exit 1
fi
echo "  unpacked: $VERSION, Gatekeeper accepted, ticket valid"

echo
echo "Release asset ready:"
printf '  %s  (%s)\n' "$ZIP" "$(du -sh "$ZIP" | cut -f1)"
printf '  %s\n' "$(cat "$CHECKSUM")"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "  tag: v$VERSION"
else
    echo "  tag: v$VERSION is missing — create it before publishing (git tag -a v$VERSION …)"
fi
echo
echo "Publish with: gh release create v$VERSION --title \"Folio $VERSION — …\" \\"
echo "                  --notes-file /tmp/release-notes-$VERSION.md \"$ZIP\" \"$CHECKSUM\""
