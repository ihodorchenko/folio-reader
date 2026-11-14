#!/bin/bash
# Sets the app version in the Xcode project — the single source of truth
# (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
#
#   ./scripts/set-version.sh 1.2.2        # keep the current build number
#   ./scripts/set-version.sh 1.2.2 42     # also set the build number (CFBundleVersion)
#
# app/Bundle/Info.plist is a template: it carries $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION)
# placeholders, so the Xcode build (archive included) and scripts/build-app.sh stamp the same pair
# without editing a second file. Nothing else in the repository stores a version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Folio.xcodeproj/project.xcproj"
PLIST="$ROOT/app/Bundle/Info.plist"

VERSION="${1:-}"
BUILD="${2:-}"

if [ -z "$VERSION" ]; then
    echo "usage: $(basename "$0") X.Y[.Z] [build-number]" >&2
    exit 2
fi
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: invalid version '$VERSION' (expected X.Y or X.Y.Z)" >&2
    exit 2
fi

if [ -z "$BUILD" ]; then
    BUILD="$(python3 - "$PROJECT" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r'"CURRENT_PROJECT_VERSION"\s*:\s*"([^"]*)"', text)
print(match.group(1) if match else "1")
PY
)"
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: invalid build number '$BUILD'" >&2
    exit 2
fi

python3 - "$PROJECT" "$VERSION" "$BUILD" <<'PY'
import re, sys

path, version, build = sys.argv[1:4]
text = open(path).read()

def replace_once(text, key, value):
    pattern = r'("%s"\s*:\s*)"[^"]*"' % re.escape(key)
    text, count = re.subn(pattern, lambda m: m.group(1) + '"' + value + '"', text)
    if count != 1:
        raise SystemExit(f"error: expected exactly one {key} in {path}, found {count}")
    return text

text = replace_once(text, "MARKETING_VERSION", version)
text = replace_once(text, "CURRENT_PROJECT_VERSION", build)
open(path, "w").write(text)
PY

# Validate the JSON project (it is the only file we touch) and the plist template.
xcrun xcprojformatter "$PROJECT" >/dev/null
plutil -lint "$PLIST" >/dev/null

echo "version: $VERSION ($BUILD) — Folio.xcodeproj (the only place a version lives)"
