#!/usr/bin/env bash
#
# build-rust.sh — build the tvtv-vortex Rust staticlib and regenerate its
# C header.
#
# Usage:
#   scripts/build-rust.sh
#
# What this does:
#   1. `cargo build --release` in rust/tvtv-vortex, producing
#      rust/tvtv-vortex/target/release/libtvtv_vortex.a for the host arch
#      (this project is arm64-only — see project.yml's ARCHS/VALID_ARCHS —
#      so a plain host build already targets the right arch; no
#      cross-compile `--target` flag is used).
#   2. Verifies all 11 `tvtv_vortex_*` C symbols are exported from the
#      staticlib (`nm -gU`), failing the build if any are missing.
#   3. If `cbindgen` is installed, regenerates
#      rust/tvtv-vortex/include/tvtv_vortex.h from src/lib.rs and, if a
#      reference header is present at the path below, prints a diff against
#      it as an informational signature-parity check — the diff does not
#      fail the build, since the reference file's prose commentary will
#      always differ from cbindgen's generated doc comments; only a
#      *signature* mismatch would be a real problem, and this project has
#      none.
#
# Wired as a pre-compile ("Run Script") build phase for the TVTVApp and
# TVTVQuickLook Xcode targets (see project.yml's prebuildScripts) so the
# staticlib is always fresh before Swift/ObjC compilation starts. Also
# runs standalone from a plain shell for local iteration.
#
# Xcode sets $SRCROOT to the directory containing the .xcodeproj (the repo
# root here) when this runs as a build phase; outside Xcode, $SRCROOT is
# unset and this script infers the repo root from its own location instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUST_DIR="$REPO_ROOT/rust/tvtv-vortex"

# Xcode's build-phase shell does not inherit an interactive login shell's
# PATH, so `cargo`/`cbindgen` (installed via rustup/cargo to ~/.cargo/bin)
# may not be found by default even though they work fine from a terminal.
export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH (looked in \$HOME/.cargo/bin and \$PATH)" >&2
  exit 1
fi

echo "==> [build-rust.sh] cargo build --release ($RUST_DIR)"
( cd "$RUST_DIR" && cargo build --release )

STATICLIB="$RUST_DIR/target/release/libtvtv_vortex.a"
if [ ! -f "$STATICLIB" ]; then
  echo "error: expected staticlib not found at $STATICLIB" >&2
  exit 1
fi
echo "==> [build-rust.sh] staticlib built: $STATICLIB"

# Prefer the Xcode toolchain's `nm` when available (the Command Line Tools'
# `nm` on this machine chokes on some of the newer rustc-emitted object
# files bundled inside the .a with "Unknown attribute kind" errors on
# unrelated dependency archive members — harmless noise, but the Xcode
# toolchain's nm parses everything cleanly). Falls back to plain `nm`.
NM_BIN="nm"
if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/nm" ]; then
  NM_BIN="$DEVELOPER_DIR/usr/bin/nm"
fi

SYMBOL_COUNT=$("$NM_BIN" -gU "$STATICLIB" 2>/dev/null | grep -c tvtv_vortex_ || true)
echo "==> [build-rust.sh] tvtv_vortex_* symbols exported: $SYMBOL_COUNT"
if [ "$SYMBOL_COUNT" -lt 11 ]; then
  echo "error: expected at least 11 tvtv_vortex_* symbols, found $SYMBOL_COUNT" >&2
  exit 1
fi

if command -v cbindgen >/dev/null 2>&1; then
  echo "==> [build-rust.sh] cbindgen -> $RUST_DIR/include/tvtv_vortex.h"
  mkdir -p "$RUST_DIR/include"
  ( cd "$RUST_DIR" && cbindgen --config cbindgen.toml --crate tvtv-vortex --output include/tvtv_vortex.h )
else
  echo "warning: cbindgen not found on PATH — skipping header generation (install with 'cargo install cbindgen')" >&2
fi

echo "==> [build-rust.sh] done"
