#!/bin/bash
# Builds the Rust core and places the dylib next to the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$(cd "$ROOT/.." && pwd)/.toolchain"

# Optional project-local toolchain (used during development); otherwise rely on PATH.
if [ -d "$TOOLCHAIN/cargo" ] && [ -d "$TOOLCHAIN/rustup" ]; then
  export RUSTUP_HOME="$TOOLCHAIN/rustup"
  export CARGO_HOME="$TOOLCHAIN/cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
command -v cargo >/dev/null 2>&1 || {
  echo "cargo not found: install Rust from https://rustup.rs" >&2
  exit 1
}

cd "$ROOT/core"
cargo build --release "$@"

mkdir -p "$ROOT/app/.build/core"
cp "$ROOT/core/target/release/libpdfcore.dylib" "$ROOT/app/.build/core/libpdfcore.dylib"
# arm64 macOS only loads signed images; an ad-hoc signature is enough.
codesign --force --sign - "$ROOT/app/.build/core/libpdfcore.dylib" 2>/dev/null || true
echo "OK: $ROOT/app/.build/core/libpdfcore.dylib"
