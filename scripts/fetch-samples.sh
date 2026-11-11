#!/bin/bash
# Downloads the third-party test document used by the acceptance checks and
# integration tests. The arXiv paper is not committed to this repository,
# it is fetched on demand for local testing only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/samples"
TARGET="$DEST/attention.pdf"
URL="${ATTENTION_PDF_URL:-https://arxiv.org/pdf/1706.03762}"

mkdir -p "$DEST"
if [ -s "$TARGET" ] && [ "$(wc -c < "$TARGET")" -gt 1000000 ]; then
  echo "samples/attention.pdf already present"
  exit 0
fi

echo "Downloading test paper: $URL"
curl -sSL -m 120 -o "$TARGET.part" "$URL"
mv "$TARGET.part" "$TARGET"

if [ ! -s "$TARGET" ]; then
  echo "download failed: $TARGET is empty" >&2
  exit 1
fi
echo "OK: samples/attention.pdf ($(du -h "$TARGET" | cut -f1))"
echo "Note: 'Attention Is All You Need' (Vaswani et al., arXiv:1706.03762) is used"
echo "      solely as a local test fixture; see https://arxiv.org/abs/1706.03762"
