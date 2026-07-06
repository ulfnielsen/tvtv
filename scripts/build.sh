#!/usr/bin/env bash
#
# build.sh — build TVTV.app into the repo (not ~/Library) and report where.
#
# Usage:
#   scripts/build.sh              # Debug build  -> dist/TVTV.app
#   scripts/build.sh --release    # Release build
#   scripts/build.sh --run        # build, then launch the app
#   scripts/build.sh --reveal     # build, then reveal the .app in Finder
#   scripts/build.sh --verbose    # don't filter xcodebuild output
#
# Why this script exists:
#   * By default `xcodebuild` buries products in
#     ~/Library/Developer/Xcode/DerivedData/<hashed-name>/… — inconvenient for
#     a CLI workflow. We force `-derivedDataPath build/xcode` so ALL Xcode
#     intermediates stay inside the repo (git-ignored), and then copy the
#     finished bundle to a stable, predictable ./dist/TVTV.app.
#   * This machine's `xcode-select` points at CommandLineTools, so we force
#     DEVELOPER_DIR to the full Xcode toolchain.
#   * The Rust staticlib is built automatically as an Xcode build phase.
#   * macOS-only app: the harmless "CoreSimulator is out of date / iOS
#     Simulator" chatter xcodebuild prints is filtered out by default (it does
#     not affect the build). Use --verbose to see the raw output.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Default to an OPTIMIZED Release build — this is the app you actually run, and
# a Debug Swift build is dramatically slower (measured ~4.6s vs ~3.0s open on a
# 5.7GB parquet). Use --debug for a fast dev-loop build.
CONFIG="Release"
ACTION=""       # "", "run", or "reveal"
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="Release" ;;
        --debug)   CONFIG="Debug" ;;
        --run)     ACTION="run" ;;
        --reveal)  ACTION="reveal" ;;
        --verbose) VERBOSE=1 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

DERIVED="$REPO_ROOT/build/xcode"
DIST="$REPO_ROOT/dist"

# Benign, macOS-irrelevant simulator chatter to hide unless --verbose.
NOISE='CoreSimulator|iOSSimulator|DVTCoreSimulator|DVTErrorPresenter|Simulator device support disabled|Unable to load simulator|version of the CoreSimulator framework|installed all available updates to your Mac|most recent version of Xcode supported'

echo "==> Building TVTV.app ($CONFIG)  [derivedData: build/xcode]"

set +e
if [ "$VERBOSE" -eq 1 ]; then
    xcodebuild \
        -project TVTV.xcodeproj -scheme TVTVApp -configuration "$CONFIG" \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" build
    STATUS=$?
else
    # Merge both streams, drop the simulator noise, keep the real exit code.
    xcodebuild \
        -project TVTV.xcodeproj -scheme TVTVApp -configuration "$CONFIG" \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" build 2>&1 \
        | grep -avE "$NOISE"
    STATUS=${PIPESTATUS[0]}
fi
set -e

if [ "$STATUS" -ne 0 ]; then
    echo "❌ Build failed (xcodebuild exit $STATUS). Re-run with --verbose for full output." >&2
    exit "$STATUS"
fi

BUILT_APP="$DERIVED/Build/Products/$CONFIG/TVTV.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "⚠️  Build reported success but bundle not found at: $BUILT_APP" >&2
    exit 1
fi

# Publish a clean, predictable copy at ./dist/TVTV.app.
mkdir -p "$DIST"
rm -rf "$DIST/TVTV.app"
cp -R "$BUILT_APP" "$DIST/TVTV.app"

echo
echo "✅ Built: dist/TVTV.app   ($(du -sh "$DIST/TVTV.app" | awk '{print $1}'))"
echo "   full path: $DIST/TVTV.app"

case "$ACTION" in
    run)    echo "==> Launching…";           open "$DIST/TVTV.app" ;;
    reveal) echo "==> Revealing in Finder…";  open -R "$DIST/TVTV.app" ;;
esac
