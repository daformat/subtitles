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
export MACOSX_DEPLOYMENT_TARGET=14.2

# VERSION is what people see. BUILD is the monotonic one and must never go
# backwards or repeat: macOS caches bundle metadata by identifier, and a version
# that reappears with different contents makes it serve the stale one.
VERSION="1.3.4"
BUILD="15"

echo "==> building rust core"
(cd core && cargo build --release)

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

> "$APP/Contents/Info.plist" cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>subtitles</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleIdentifier</key>         <string>dev.mat.subtitles</string>
    <key>CFBundleName</key>               <string>Subtitles</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>     <string>14.2</string>
    <!-- NSHumanReadableCopyright is deliberately absent. It was dropped when the
         About panel drew it as a line of its own, always last, below the author
         links that belong under it. The About window is ours now and could read
         it again — but the string lives in About.swift beside the rest of the
         credits, and Finder's Get Info is the only thing that misses it. -->
    <!-- Required for the audio-capture TCC grant. Without it the tap returns
         all-zero samples and reports no error whatsoever. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Subtitles transcribes the audio your Mac is playing so it can show live captions.</string>
    <!-- Agent app: no Dock icon, no menu bar. -->
    <key>LSUIElement</key>                <true/>
</dict>
</plist>
PLIST

echo "==> compiling swift app (SwiftPM)"
# SwiftPM rather than raw swiftc because FluidAudio is only distributed as a
# Swift package. The Rust core is linked via linkerSettings in Package.swift;
# it must already be built, which is why cargo runs first.
# Do NOT pipe this through `grep ... || true`: that masks a failed build, and the
# stale binary from the previous run then gets copied into the bundle and shipped.
# Cost an hour of debugging a "fix" that was never compiled.
if ! swift build -c release > "$OUT/swift-build.log" 2>&1; then
  grep -E "error:" "$OUT/swift-build.log" | head -20 >&2
  echo "!! swift build failed (full log: $OUT/swift-build.log)" >&2
  exit 1
fi
grep -vE "was built for newer 'macOS' version|ld: warning: object file" "$OUT/swift-build.log" \
  | grep -E "^Compiling|^Build complete" || true

BIN=".build/release/subtitles"
[ -x "$BIN" ] || { echo "!! swift build produced no binary" >&2; exit 1; }
cp "$BIN" "$APP/Contents/MacOS/subtitles"

# SwiftPM emits resource bundles beside the binary; they must travel with the app
# or anything depending on them fails only at runtime, on the code path that uses
# them.
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
  echo "    bundled $(basename "$bundle")"
done

if [ ! -x "$APP/Contents/MacOS/subtitles" ]; then
  echo "!! swift link failed" >&2
  exit 1
fi

# The status icon, and the two marks the About window puts beside its links.
# Copied rather than declared as SwiftPM resources because the bundle here is
# assembled by hand, not by SwiftPM. NSImage reads SVG directly on macOS 13+,
# so there is no conversion step.
cp app/macos/StatusIcon.svg app/macos/LogoMat.svg app/macos/LogoTwitter.svg \
   "$APP/Contents/Resources/"

# The welcome window's demo, vendored from the website by tools/vendor-demo.sh.
# demo.shell.html is the template that script splices demo.html out of, and has
# no business in the bundle.
mkdir -p "$APP/Contents/Resources/Demo"
cp app/macos/Demo/demo.html app/macos/Demo/demo.css app/macos/Demo/demo.js \
   "$APP/Contents/Resources/Demo/"

# The app icon. Built from the one PNG rather than committing an .icns, so there
# is a single source of truth to edit. Cached against the source's timestamp:
# ten sips resizes is a couple of seconds, which is real money on a rebuild loop
# that otherwise takes ten.
#
# The app is LSUIElement and has no Dock icon, so this is for Finder, Get Info,
# notifications, and — the one that matters — the audio entry in System Settings
# ▸ Privacy & Security.
ICNS="$OUT/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ app/macos/AppIcon.png -nt "$ICNS" ] \
   || [ tools/makeappicon.swift -nt "$ICNS" ]; then
  echo "==> app icon"
  # Shape it first. The source is a full-bleed square; macOS will not round it,
  # so without this step the icon is a hard-edged tile beside every other app.
  MASTER="$OUT/AppIcon-shaped.png"
  swift tools/makeappicon.swift app/macos/AppIcon.png "$MASTER"
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$MASTER" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
  # The README's copy, which has to be a tracked file for GitHub to serve it.
  # Written here so it cannot drift from the icon it claims to show; this whole
  # block only runs when the source actually changes, so an ordinary rebuild
  # never touches the working tree.
  sips -z 256 256 "$MASTER" --out docs/icon.png >/dev/null
  echo "    $(du -h "$ICNS" | cut -f1) from app/macos/AppIcon.png, plus docs/icon.png"
fi
cp "$ICNS" "$APP/Contents/Resources/"

echo "==> third-party notices"
# Apache-2.0 §4(a) requires giving recipients a copy of the licence, so it has to
# travel inside the bundle rather than living only in the repo.
#
# Assembled from the checkout rather than a copy kept here: a copy silently goes
# stale when the dependency is bumped, and the failure mode is shipping the wrong
# licence text. FluidAudio ships no NOTICE file, so §4(d) does not apply; it does
# vendor fastcluster and VBx, which travel with it into the binary.
#
# Only FluidAudio matters here. It is the sole package dependency, and the Rust
# core has no runtime dependencies — everything in core/Cargo.lock is cbindgen's
# build-time tree and never reaches the binary.
FA=".build/checkouts/FluidAudio"
NOTICES="$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
[ -d "$FA" ] || { echo "!! FluidAudio checkout missing; cannot build notices" >&2; exit 1; }
{
  echo "Subtitles — third-party notices"
  echo
  echo "Subtitles itself is FSL-1.1-ALv2 (see LICENSE), which converts to"
  echo "Apache-2.0 two years after each release."
  echo "The components below are compiled into this application."
  echo
  echo "The speech models are NOT included in this application. They are"
  echo "downloaded from HuggingFace on first use and carry their own terms:"
  echo "  Parakeet EOU, Nemotron Streaming EN  NVIDIA Open Model License"
  echo "  Parakeet Unified, Sortformer         CC-BY-4.0"
  echo "  Nemotron 3.5 Multilingual            OpenMDW-1.1"
  echo "  Silero VAD                           MIT"
  echo
  printf '=%.0s' {1..78}; echo
  echo "FluidAudio — https://github.com/FluidInference/FluidAudio"
  printf '=%.0s' {1..78}; echo
  echo
  cat "$FA/LICENSE"
  for lic in "$FA/ThirdPartyLicenses/"*; do
    [ -e "$lic" ] || continue
    echo
    printf '=%.0s' {1..78}; echo
    echo "Vendored by FluidAudio — $(basename "$lic" | sed 's/-LICENSE\.md$//')"
    printf '=%.0s' {1..78}; echo
    echo
    cat "$lic"
  done
} > "$NOTICES"
echo "    $(wc -l < "$NOTICES" | tr -d ' ') lines from $(ls "$FA/ThirdPartyLicenses" | wc -l | tr -d ' ') vendored licences + FluidAudio"

echo "==> signing"
# Developer ID rather than ad-hoc, for two reasons. Notarization refuses
# anything else — but the one that shows up daily is that the cdhash is now
# stable across rebuilds, so the TCC audio grant survives one instead of being
# reissued against a new identity every time. That is the whole "every rebuild
# prompts again" problem in the README, and it goes away here.
#
# Falls back to ad-hoc when the certificate is absent (a fresh clone, another
# machine). The app still builds and runs; it just re-prompts for permission
# after every build, exactly as it always did.
IDENTITY="${SUBTITLES_SIGN_IDENTITY:-Developer ID Application}"
ENTS="app/macos/Subtitles.entitlements"

# Captured rather than piped: `grep -q` exits at the first match and the writer
# takes SIGPIPE, which `set -o pipefail` turns into a failed pipeline. Piped, this
# test loses a race some fraction of the time and quietly signs ad-hoc instead —
# which is worse than failing, because the build succeeds and the reason it will
# not notarize is buried mid-log.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if grep -q "$IDENTITY" <<<"$IDENTITIES"; then
  # --options runtime is the hardened runtime, required by notarization.
  # --timestamp binds a trusted timestamp, so signatures stay valid after the
  # certificate expires; it needs the network and fails loudly without it.
  SIGN=(--force --sign "$IDENTITY" --options runtime --timestamp)
  REAL_IDENTITY=yes
  echo "    $IDENTITY"
  echo "    hardened runtime, timestamped, entitlements from $ENTS"
else
  SIGN=(--force --sign -)
  REAL_IDENTITY=no
  echo "    !! no '$IDENTITY' certificate on this machine — signing ad-hoc"
  echo "    !! macOS will re-prompt for audio permission after every build,"
  echo "    !! and this bundle cannot be notarized. Fine for local work."
fi

# Inside out. A signature seals the bundle's contents, so signing the app first
# and something inside it second silently invalidates the outer seal — codesign
# reports success both times and notarization rejects the result. Entitlements
# go on the app alone; a resource bundle carrying them is a review flag.
for bundle in "$APP/Contents/Resources/"*.bundle; do
  [ -e "$bundle" ] || continue
  codesign "${SIGN[@]}" "$bundle"
  echo "    signed $(basename "$bundle")"
done

if [ "$REAL_IDENTITY" = yes ]; then
  codesign "${SIGN[@]}" --entitlements "$ENTS" --identifier dev.mat.subtitles "$APP"
else
  codesign "${SIGN[@]}" --identifier dev.mat.subtitles "$APP"
fi

# --strict catches the sealing mistake above; the plain verify does not.
codesign --verify --strict --deep "$APP"

echo
echo "built $APP  ($VERSION, build $BUILD)"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Developer ID Application|TeamIdentifier|flags=" || true
echo
echo "run it with:  ./run.sh"
