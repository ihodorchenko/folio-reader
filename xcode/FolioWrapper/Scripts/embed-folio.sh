#!/bin/bash
# Assembles the real Folio.app (built by scripts/build-app.sh) inside the Xcode
# product so Xcode's CodeSign / Distribute App steps sign it with a Developer ID.
#
# Inputs:
#   $TARGET_BUILD_DIR/$WRAPPER_NAME  the product bundle Xcode is building
#   $SRCROOT/../../dist/Folio.app    the app built by scripts/build-app.sh
set -euo pipefail

APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
SRC="${SRCROOT}/../../dist/Folio.app"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC not found — run ./scripts/build-app.sh first" >&2
    exit 1
fi

echo "Embedding $SRC into $APP"
rsync -a --delete "$SRC/" "$APP/"

# Xcode signs the app bundle at the end of the build, but it refuses to sign a
# bundle whose nested dylibs are not signed at all. Sign them here with the
# identity Xcode is going to use (Development for the archive; Xcode re-signs
# the whole bundle with the Developer ID during Distribute App).
IDENT="${EXPANDED_CODE_SIGN_IDENTITY:-}"
for lib in "$APP/Contents/Frameworks/"*.dylib; do
    [ -f "$lib" ] || continue
    if [ -n "$IDENT" ] && [ "$IDENT" != "-" ]; then
        codesign --force --options runtime --timestamp --sign "$IDENT" "$lib"
    else
        codesign --force --sign - "$lib"
    fi
done
