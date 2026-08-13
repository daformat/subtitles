#!/bin/bash
# Answers one question: is the system-audio capture permission actually granted?
#
# There is no API to ask. Spike 0B Finding 1: when the grant is missing, every
# Core Audio call still returns noErr, the device runs, and buffers arrive at the
# right size and cadence — filled entirely with zeros. So the only reliable test
# is empirical: play a known sound and see whether any non-zero sample arrives.
#
# Run this BEFORE any transcription test. Otherwise you race the permission
# dialog and misread "not approved yet" as "the pipeline is broken".
set -uo pipefail

cd "$(dirname "$0")"
APP="$PWD/build/Subtitles.app"
LOG="$PWD/build/probe.log"
TONE="/System/Library/Sounds/Submarine.aiff"

[ -d "$APP" ] || { echo "not built — run ./build.sh" >&2; exit 1; }

pkill -f "Subtitles.app/Contents/MacOS/subtitles" 2>/dev/null && sleep 0.5
: > "$LOG"

echo "starting app (model load takes ~10s)…"
# `open -W` backgrounded, not a bare `open`: once a non-waiting `open` exits, the
# redirected stdout/stderr stop receiving the app's later output, so everything
# after the first second or two silently vanishes from the log.
open -W --stdout "$LOG" --stderr "$LOG" "$APP" &
OPEN_PID=$!

for _ in $(seq 1 90); do
  grep -qa "listening. ctrl-C" "$LOG" && break
  sleep 1
done
if ! grep -qa "listening. ctrl-C" "$LOG"; then
  echo "✗ app never reached the listening state. Log:" >&2
  tail -5 "$LOG" >&2
  pkill -f "Subtitles.app/Contents/MacOS/subtitles" 2>/dev/null
  exit 1
fi

# Retry loop: every ./build.sh re-signs ad-hoc, which changes the binary's
# cdhash. TCC identifies ad-hoc-signed apps by that hash, so a rebuild looks like
# a brand-new app and prompts again. Without waiting here, a test races the
# dialog and reads "not approved yet" as a broken pipeline.
ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "playing a test tone for ~5s… (attempt $ATTEMPT)"
( for _ in 1 2 3; do afplay "$TONE"; done ) &
TONE_PID=$!
sleep 6
kill "$TONE_PID" 2>/dev/null; wait "$TONE_PID" 2>/dev/null

# Peak dBFS the core reported while the tone played. -120 means digital silence.
  PEAK=$(tr '\r' '\n' < "$LOG" \
         | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' \
         | grep -oaE '(listening|idle) -?[0-9]+dB' \
         | grep -oE '\-?[0-9]+' | sort -n | tail -1)

  if [ -n "${PEAK:-}" ] && [ "$PEAK" -gt -119 ]; then break; fi
  if [ "$ATTEMPT" -ge 12 ]; then break; fi
  echo "   still silence — approve the permission dialog if it is showing; retrying…"
  : > "$LOG"
  sleep 5
done

pkill -f "Subtitles.app/Contents/MacOS/subtitles" 2>/dev/null
kill "$OPEN_PID" 2>/dev/null

echo
if [ -z "${PEAK:-}" ]; then
  echo "? inconclusive — no level readings in the log"
  exit 2
elif [ "$PEAK" -le -119 ]; then
  cat <<EOF
✗ NOT GRANTED — peak level ${PEAK} dBFS (digital silence) while audio was playing.

Core Audio reported no error; it simply hands us zeros. Fix:
  • System Settings → Privacy & Security → check for Subtitles under audio
    recording, and approve the prompt if it is waiting.
  • Always launch via ./run.sh — running the binary directly makes the terminal
    the TCC-responsible process and the grant will not apply.
  • Note every ./build.sh re-signs ad-hoc and changes the cdhash, so macOS asks
    again after each rebuild. See PLAN.md for the stable-identity fix that stops
    the repeat prompts.
EOF
  exit 1
else
  echo "✓ GRANTED — peak level ${PEAK} dBFS while audio played. Real samples are arriving."
  exit 0
fi
