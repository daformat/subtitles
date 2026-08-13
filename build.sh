#!/bin/bash
# Builds the Rust core, links the Swift app against it, and assembles a signed
# .app bundle.
#
# The bundle is not cosmetic: process taps need a bundle identifier and
# NSAudioCaptureUsageDescription for TCC to grant audio capture at all, and the
# signature must bind the Info.plist. See PLAN.md §8b.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
OUT="$ROOT/build"
APP="$OUT/Subtitles.app"
SHERPA="$ROOT/third_party/sherpa-onnx"
export MACOSX_DEPLOYMENT_TARGET=14.2

echo "==> building rust core"
(cd core && cargo build --release)

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>subtitles</string>
    <key>CFBundleIdentifier</key>         <string>dev.mat.subtitles</string>
    <key>CFBundleName</key>               <string>Subtitles</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>LSMinimumSystemVersion</key>     <string>14.2</string>
    <!-- Required for the audio-capture TCC grant. Without it the tap returns
         all-zero samples and reports no error whatsoever. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Subtitles transcribes the audio your Mac is playing so it can show live captions.</string>
    <!-- Agent app: no Dock icon, no menu bar. -->
    <key>LSUIElement</key>                <true/>
</dict>
</plist>
PLIST

echo "==> compiling swift app"
swiftc -O \
  -o "$APP/Contents/MacOS/subtitles" \
  -import-objc-header "$ROOT/core/include/subs.h" \
  "$ROOT/app/macos/SystemAudioTap.swift" \
  "$ROOT/app/macos/Overlay.swift" \
  "$ROOT/app/macos/Hotkey.swift" \
  "$ROOT/app/macos/MenuBar.swift" \
  "$ROOT/app/macos/main.swift" \
  "$ROOT/core/target/release/libsubs_core.a" \
  "$SHERPA/lib/libsherpa-onnx-c-api.a" \
  "$SHERPA/lib/libsherpa-onnx-core.a" \
  "$SHERPA/lib/libkaldi-native-fbank-core.a" \
  "$SHERPA/lib/libkaldi-decoder-core.a" \
  "$SHERPA/lib/libsherpa-onnx-kaldifst-core.a" \
  "$SHERPA/lib/libsherpa-onnx-fst.a" \
  "$SHERPA/lib/libsherpa-onnx-fstfar.a" \
  "$SHERPA/lib/libssentencepiece_core.a" \
  "$SHERPA/lib/libkissfft-float.a" \
  "$SHERPA/lib/libonnxruntime.a" \
  -lc++ \
  -framework CoreAudio -framework AudioToolbox -framework Foundation \
  -framework CoreML -framework Accelerate \
  2>&1 | grep -vE "was built for newer 'macOS' version|ld: warning: object file" || true

if [ ! -x "$APP/Contents/MacOS/subtitles" ]; then
  echo "!! swift link failed" >&2
  exit 1
fi

echo "==> signing"
# Ad-hoc is enough for local dev; what matters is that the Info.plist is bound
# into the signature so TCC can identify the app.
codesign --force --sign - --identifier dev.mat.subtitles "$APP"

echo
echo "built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Info.plist"
echo
echo "run it with:  ./run.sh"
