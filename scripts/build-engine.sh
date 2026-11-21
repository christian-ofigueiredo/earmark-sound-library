#!/bin/bash
# Builds the Rust engine for the Mac app (docs/rust-engine-plan.md, step 8):
#
#   app/Engine/EarmarkFFI.xcframework                   the engine as a static library, with its C header
#   app/Sources/EarmarkEngine/Generated/earmark_ffi.swift  the Swift side, written by UniFFI
#   engine/target/release/earmark-mcp                   the MCP server agents start (build-app.sh ships it)
#
# Both are made from engine/crates/earmark-ffi and aren't in the repository. Run this before
# `swift build` in app/ (scripts/build-app.sh does).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"
OUT="$ROOT/app/Engine"
GENERATED="$ROOT/app/Sources/EarmarkEngine/Generated"
# As in app/Package.swift, so the linker doesn't warn about a newer system.
export MACOSX_DEPLOYMENT_TARGET="14.0"
command -v cargo > /dev/null || export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

cd "$ENGINE"
# Two builds: the app's engine with the system's SQLite (the one GRDB uses: two copies of SQLite
# in one process can lose each other's locks on the same file), the MCP server, its own process,
# with SQLite built in. Built together, Cargo would give both the built-in one.
cargo build --locked --release -p earmark-ffi -p uniffi-bindgen
cargo build --locked --release -p earmark-mcp
LIB="$ENGINE/target/release"

WORK="$(mktemp -d -t earmark-engine)"
trap 'rm -rf "$WORK"' EXIT
"$LIB/uniffi-bindgen" generate --library "$LIB/libearmark_ffi.dylib" --language swift --out-dir "$WORK" > /dev/null

mkdir -p "$WORK/headers" "$GENERATED"
cp "$WORK/earmark_ffiFFI.h" "$WORK/headers/"
# The framework's module map must be called module.modulemap.
cp "$WORK/earmark_ffiFFI.modulemap" "$WORK/headers/module.modulemap"
cp "$WORK/earmark_ffi.swift" "$GENERATED/earmark_ffi.swift"

rm -rf "$OUT/EarmarkFFI.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework -library "$LIB/libearmark_ffi.a" -headers "$WORK/headers" \
    -output "$OUT/EarmarkFFI.xcframework" > /dev/null
echo "Engine: $OUT/EarmarkFFI.xcframework"
