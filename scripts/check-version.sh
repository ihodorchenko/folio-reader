#!/bin/bash
# The app version has exactly one source: the Xcode project
# (MARKETING_VERSION → CFBundleShortVersionString, CURRENT_PROJECT_VERSION → CFBundleVersion).
# app/Bundle/Info.plist must only *refer* to those settings, so a second copy cannot drift.
#
#   ./scripts/check-version.sh          # CI: the project defines the version, the plist refers to it
#   ./scripts/check-version.sh 1.2.2    # release: the project version must also match the expected one
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Folio.xcodeproj/project.xcproj"
PLIST="$ROOT/app/Bundle/Info.plist"
EXPECTED="${1:-}"

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

VERSION="$(project_value MARKETING_VERSION)"
BUILD="$(project_value CURRENT_PROJECT_VERSION)"

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    echo "error: the project defines an empty version ($VERSION) or build number ($BUILD)" >&2
    exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"

if [ "$PLIST_VERSION" != '$(MARKETING_VERSION)' ] || [ "$PLIST_BUILD" != '$(CURRENT_PROJECT_VERSION)' ]; then
    echo "error: Info.plist must reference the project settings, not a hard-coded version" >&2
    echo "       expected CFBundleShortVersionString = \$(MARKETING_VERSION)," \
         "CFBundleVersion = \$(CURRENT_PROJECT_VERSION)" >&2
    echo "       found    CFBundleShortVersionString = $PLIST_VERSION, CFBundleVersion = $PLIST_BUILD" >&2
    exit 1
fi

if [ -n "$EXPECTED" ] && [ "$VERSION" != "$EXPECTED" ]; then
    echo "error: expected version $EXPECTED does not match the project's $VERSION" >&2
    echo "       run ./scripts/set-version.sh $EXPECTED before tagging" >&2
    exit 1
fi

echo "version consistency OK: $VERSION ($BUILD) — single source: Folio.xcodeproj + Info.plist placeholders"
