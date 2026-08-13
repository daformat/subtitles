#!/bin/bash
# Launches the app via `open` and streams its output back to this terminal.
#
# This indirection is load-bearing. Executing the binary directly makes the
# terminal the TCC-responsible process; the audio-capture grant then does not
# apply and the tap delivers perfectly-timed all-zero buffers with no error
# anywhere (Spike 0B Finding 2). Launched through launchd, the app is its own
# responsible process and the grant works.
set -euo pipefail

cd "$(dirname "$0")"
APP="$PWD/build/Subtitles.app"
LOG="$PWD/build/subtitles.log"

[ -d "$APP" ] || { echo "not built yet — run ./build.sh" >&2; exit 1; }

# Kill any previous instance FIRST. `open` activates an already-running app
# rather than launching the new binary, so without this you silently keep
# testing the last build and misread stale behaviour as your fix working.
if pkill -f "Subtitles.app/Contents/MacOS/subtitles" 2>/dev/null; then
  echo "(stopped previous instance)"
  sleep 0.5
fi

: > "$LOG"
open -W --stdout "$LOG" --stderr "$LOG" "$APP" --args "$@" &
OPEN_PID=$!

cleanup() {
  kill "$OPEN_PID" 2>/dev/null || true
  pkill -f "Subtitles.app/Contents/MacOS/subtitles" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait for the log to appear, then follow it.
for _ in $(seq 1 50); do [ -s "$LOG" ] && break; sleep 0.1; done
tail -f "$LOG" &
TAIL_PID=$!
wait "$OPEN_PID" 2>/dev/null || true
kill "$TAIL_PID" 2>/dev/null || true
