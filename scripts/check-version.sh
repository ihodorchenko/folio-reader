#!/bin/bash
# Fails when the version in app/Bundle/Info.plist and Folio.xcodeproj diverge,
# and (optionally) when it does not match the expected release tag version.
#
#   ./scripts/check-version.sh          # CI: project and plist must agree
#   ./scripts/check-version.sh 1.2.1    # release: also match the tag version
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

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
PROJECT_VERSION=$(project_value MARKETING_VERSION)
PROJECT_BUILD=$(project_value CURRENT_PROJECT_VERSION)

if [ "$PLIST_VERSION" != "$PROJECT_VERSION" ] || [ "$PLIST_BUILD" != "$PROJECT_BUILD" ]; then
    echo "error: version mismatch — Info.plist $PLIST_VERSION ($PLIST_BUILD) vs" >&2
    echo "       Folio.xcodeproj $PROJECT_VERSION ($PROJECT_BUILD)" >&2
    echo "       run ./scripts/set-version.sh <version> to synchronize them" >&2
    exit 1
fi

if [ -n "$EXPECTED" ] && [ "$PLIST_VERSION" != "$EXPECTED" ]; then
    echo "error: release tag version $EXPECTED does not match the app version $PLIST_VERSION" >&2
    echo "       run ./scripts/set-version.sh $EXPECTED before tagging" >&2
    exit 1
fi

echo "version consistency OK: $PLIST_VERSION ($PLIST_BUILD)"
