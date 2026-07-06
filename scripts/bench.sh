#!/usr/bin/env bash
#
# bench.sh — cold-open wall-time + peak-RSS benchmark for TVTV-style apps.
#
# Usage:
#   scripts/bench.sh <app-bundle-path> <file>
#
# Examples:
#   scripts/bench.sh dist/TVTV.app data/bench/smoke_wide.parquet
#   scripts/bench.sh .build/Build/Products/Debug/TVTV.app data/bench/wide_100m.parquet
#
# What this script measures:
#
#   * Cold-open wall time: wall-clock seconds from `open -a <bundle> <file>`
#     until the launched process's RSS has stopped growing (polled via `ps`
#     at a fast interval, N consecutive samples within a small tolerance).
#     macOS gives no public, scriptable "this document finished loading and
#     is on screen" signal for an arbitrary .app, so RSS stabilization is
#     used as a proxy for "done loading". Treat the number as an estimate;
#     cross-check with a stopwatch/screen recording for anything load-bearing.
#     Any already-running instance of the target app is terminated first so
#     the measured launch is a genuine cold start.
#
#   * Peak RSS: the maximum `ps -o rss=` sample observed for the app's PID
#     over the open+load window, reported in MB. For a more detailed/
#     authoritative memory breakdown, run `footprint <pid>` or
#     `vmmap <pid>` by hand against the PID this script prints.
#
# NOT measured here — Scroll FPS:
#
#   Scroll-FPS cannot be scripted reliably: there is no public API to
#   synthesize realistic trackpad/scroll input and read back actual
#   Core Animation frame timing for an arbitrary target app. Capture it
#   MANUALLY instead:
#     1. Open the file under test in the app (or let this script do it).
#     2. Launch Instruments.app -> "Core Animation" (or "Hangs") template,
#        attach to the app's process (see the PID this script prints).
#     3. Scroll through the grid continuously for ~10s, stop the trace.
#     4. Read FPS / frame-duration off the Core Animation track.
#   Record this by hand alongside bench.sh's wall-time/RSS numbers when
#   comparing build variants or tracking regressions over time.
#
# Safety: this script only launches, polls, and (for the *-cleanup* step at
# the start) terminates the target app's *process*. It never writes to,
# moves, or deletes the app bundle on disk. It is safe to point at
# dist/TVTV.app.

set -euo pipefail

RSS_POLL_INTERVAL="${BENCH_POLL_INTERVAL:-0.1}"     # seconds between RSS samples
RSS_STABLE_SAMPLES="${BENCH_STABLE_SAMPLES:-5}"      # consecutive stable samples = "loaded"
RSS_STABLE_TOLERANCE_KB="${BENCH_STABLE_TOLERANCE_KB:-2048}"  # KB drift allowed and still "stable"
MAX_WAIT_SECONDS="${BENCH_MAX_WAIT_SECONDS:-60}"     # give up after this long

usage() {
  echo "Usage: $0 <app-bundle-path> <file>" >&2
  exit 1
}

[ $# -eq 2 ] || usage

APP_BUNDLE="$1"
FILE="$2"

[ -d "$APP_BUNDLE" ] || { echo "error: app bundle not found: $APP_BUNDLE" >&2; exit 1; }
[ -f "$FILE" ] || { echo "error: file not found: $FILE" >&2; exit 1; }

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || { echo "error: not a valid app bundle (no Info.plist): $APP_BUNDLE" >&2; exit 1; }

EXEC_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" 2>/dev/null || true)"
if [ -z "$EXEC_NAME" ]; then
  echo "error: could not read CFBundleExecutable from $INFO_PLIST" >&2
  exit 1
fi

FILE_ABS="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
FILE_SIZE_BYTES=$(stat -f%z "$FILE_ABS")
FILE_SIZE_HUMAN=$(du -h "$FILE_ABS" | awk '{print $1}')

echo "bench.sh: app='$APP_BUNDLE' exec='$EXEC_NAME' file='$FILE_ABS' ($FILE_SIZE_HUMAN)"

# --- Ensure a genuine cold start: kill any running instance first --------
EXISTING_PIDS="$(pgrep -f "$EXEC_NAME" || true)"
if [ -n "$EXISTING_PIDS" ]; then
  echo "bench.sh: terminating existing instance(s): $EXISTING_PIDS"
  # shellcheck disable=SC2086
  kill $EXISTING_PIDS 2>/dev/null || true
  sleep 1
fi

# --- Launch and time until RSS stabilizes ---------------------------------
START_TS=$(date +%s.%N)

open -a "$APP_BUNDLE" "$FILE_ABS"

PID=""
ELAPSED_WAIT=0
while [ -z "$PID" ]; do
  PID="$(pgrep -nf "$EXEC_NAME" || true)"
  if [ -z "$PID" ]; then
    sleep "$RSS_POLL_INTERVAL"
    ELAPSED_WAIT=$(echo "$ELAPSED_WAIT + $RSS_POLL_INTERVAL" | bc)
    if (( $(echo "$ELAPSED_WAIT > $MAX_WAIT_SECONDS" | bc -l) )); then
      echo "error: '$EXEC_NAME' did not appear within ${MAX_WAIT_SECONDS}s" >&2
      exit 1
    fi
  fi
done
echo "bench.sh: PID=$PID"

PREV_RSS=-1
STABLE_COUNT=0
PEAK_RSS_KB=0
END_TS=""

while true; do
  RSS_KB="$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')"
  if [ -z "$RSS_KB" ]; then
    echo "error: process $PID exited before RSS stabilized" >&2
    exit 1
  fi
  if [ "$RSS_KB" -gt "$PEAK_RSS_KB" ]; then
    PEAK_RSS_KB="$RSS_KB"
  fi

  if [ "$PREV_RSS" -ge 0 ]; then
    DIFF=$(( RSS_KB - PREV_RSS ))
    [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
    if [ "$DIFF" -le "$RSS_STABLE_TOLERANCE_KB" ]; then
      STABLE_COUNT=$(( STABLE_COUNT + 1 ))
    else
      STABLE_COUNT=0
    fi
  fi
  PREV_RSS="$RSS_KB"

  if [ "$STABLE_COUNT" -ge "$RSS_STABLE_SAMPLES" ]; then
    END_TS=$(date +%s.%N)
    break
  fi

  NOW_TS=$(date +%s.%N)
  WAITED=$(echo "$NOW_TS - $START_TS" | bc)
  if (( $(echo "$WAITED > $MAX_WAIT_SECONDS" | bc -l) )); then
    echo "bench.sh: warning: RSS did not stabilize within ${MAX_WAIT_SECONDS}s, reporting anyway" >&2
    END_TS=$(date +%s.%N)
    break
  fi

  sleep "$RSS_POLL_INTERVAL"
done

OPEN_SECONDS=$(echo "$END_TS - $START_TS" | bc)
PEAK_RSS_MB=$(echo "scale=1; $PEAK_RSS_KB / 1024" | bc)

printf "RESULT app=%s file=%s(%s) pid=%s cold_open_s=%.2f peak_rss_mb=%s\n" \
  "$(basename "$APP_BUNDLE")" "$(basename "$FILE_ABS")" "$FILE_SIZE_HUMAN" \
  "$PID" "$OPEN_SECONDS" "$PEAK_RSS_MB"

echo "bench.sh: for a manual scroll-FPS pass, attach Instruments' Core Animation template to PID $PID now."
