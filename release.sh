#!/bin/bash
# Builds, packages, notarizes and staples a DMG ready to upload to Gumroad.
#
# One command per release. Everything it does is verifiable afterwards, and it
# refuses to produce a file that would fail on a customer's machine rather than
# warning and carrying on — a broken DMG is only discovered by the person who
# paid for it.
#
# Prerequisites, one-time:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials stored as a keychain profile:
#       xcrun notarytool store-credentials "subtitles-notary" \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>
set -euo pipefail

cd "$(dirname "$0")"
PROFILE="${SUBTITLES_NOTARY_PROFILE:-subtitles-notary}"

# --no-notarize builds the DMG and stops. Notarization is a three-minute round
# trip to Apple and irrelevant to how the window looks, which is the thing that
# actually needs iterating on. The result is NOT shippable.
NOTARIZE=yes
if [ "${1:-}" = "--no-notarize" ]; then NOTARIZE=no; fi

VERSION=$(grep -m1 '^VERSION=' build.sh | cut -d'"' -f2)
APP="build/Subtitles.app"
STAGE="build/dmg"
DMG="build/Subtitles-$VERSION.dmg"
RWDMG="build/Subtitles-rw.dmg"

echo "==> release $VERSION"

# Refuse to ship a dirty tree. The DMG is going to strangers who paid for it;
# "which commit was that build from" needs an answer.
if [ "$NOTARIZE" = yes ] && [ -n "$(git status --porcelain)" ]; then
  echo "!! working tree is dirty — commit or stash before releasing" >&2
  git status --short >&2
  exit 1
fi

./build.sh

# build.sh falls back to ad-hoc signing when the certificate is missing, and says
# so — but it says so in the middle of a lot of other output. Notarization would
# fail anyway; failing here explains why.
# Two traps here, both of which make a correctly signed app look unsigned:
#   -dvv, not -dv — the Authority lines only appear at the second v.
#   Captured, not piped — `grep -q` exits at the first match, codesign takes
#   SIGPIPE still writing, and `set -o pipefail` fails the whole pipeline.
SIG_INFO=$(codesign -dvv "$APP" 2>&1 || true)
if ! grep -q "Authority=Developer ID Application" <<<"$SIG_INFO"; then
  echo "!! $APP is not signed with a Developer ID — cannot notarize" >&2
  echo "   check: security find-identity -v -p codesigning" >&2
  exit 1
fi

echo "==> packaging $DMG"
rm -rf "$STAGE" "$DMG" "$RWDMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
# The drag-to-install target. Without it the window is one icon and no hint of
# what to do with it.
ln -s /Applications "$STAGE/Applications"
swift tools/makedmgbg.swift "$STAGE/.background/background.tiff"

# A volume of this name already mounted — a previous run that died before
# detaching — makes hdiutil name the new one "Subtitles 1". The layout script
# would then configure the stale volume instead, and produce an unstyled DMG
# without failing. Seen once already; it is not hypothetical.
while read -r stale; do
  [ -n "$stale" ] || continue
  echo "    detaching stale volume: $stale"
  hdiutil detach "$stale" -quiet -force 2>/dev/null || true
done < <(mount | awk -F' on | \\(' '/\/Volumes\/Subtitles/ {print $2}')

# Read-write first. The window layout — size, icon positions, background — lives
# in the volume's .DS_Store, which only Finder writes, and only on a mounted
# writable image. The compressed read-only image people download is converted
# from this one at the end.
hdiutil create -volname "Subtitles" -srcfolder "$STAGE" -ov \
  -format UDRW -fs HFS+ "$RWDMG" >/dev/null

MOUNT=$(hdiutil attach "$RWDMG" -readwrite -noverify -noautoopen \
        | tail -1 | awk -F'\t' '{print $NF}')
# Any failure from here on leaves a mounted volume behind, which makes the next
# run fail on a name collision that has nothing to do with the real problem.
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true' EXIT

# Coordinates match tools/makedmgbg.swift. Both are in AppleScript's space:
# points, origin at the window's top left. Changing one without the other points
# the arrow at empty space.
# Whatever name the volume actually got, rather than the one asked for — see
# the stale-volume guard above. Unquoted heredoc so it interpolates; the script
# below contains no $ or backslashes of its own.
VOLNAME=$(basename "$MOUNT")

if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 428, not 400: `bounds` covers the whole window including the title bar,
    -- so asking for the image's height crops the bottom of it by ~28pt.
    set the bounds of container window to {240, 130, 880, 558}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Subtitles.app" of container window to {170, 180}
    set position of item "Applications" of container window to {470, 180}
    -- Re-asserted after the contents change. Setting it once and then
    -- reopening the window loses the width, and Finder falls back to its
    -- default ~900pt — the image then sits in the corner of an oversized
    -- window with a bare white strip beside it.
    set the bounds of container window to {240, 130, 880, 558}
    update without registering applications
    delay 1
    -- Closing is what commits .DS_Store. Reopening afterwards only gives
    -- Finder another chance to resize the window before it is written.
    close
  end tell
end tell
APPLESCRIPT
then
  echo "!! Finder refused the layout script (Apple event error)." >&2
  echo "   Laying out a DMG window means driving Finder, and macOS gates that" >&2
  echo "   behind Automation permission. The first attempt normally prompts —" >&2
  echo "   but a prompt that was dismissed or denied is remembered silently, and" >&2
  echo "   a non-interactive shell cannot raise one at all." >&2
  echo "   Fix: System Settings > Privacy & Security > Automation >" >&2
  echo "        <your terminal> > Finder, then run this again." >&2
  exit 1
fi

# Finder writes .DS_Store lazily; detaching before it lands loses the layout and
# the DMG opens as a plain list with no background at all.
sync
sleep 2
hdiutil detach "$MOUNT" -quiet
trap - EXIT

hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RWDMG"
echo "    $(du -h "$DMG" | cut -f1)"

# The DMG is signed too. Otherwise Gatekeeper has nothing to check before the
# user has mounted anything, and the download looks unsigned at the worst moment.
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

if [ "$NOTARIZE" = no ]; then
  rm -rf "$STAGE"
  echo
  echo "built $DMG — NOT notarized, do not ship this one"
  echo "open it to check the window:  open $DMG"
  exit 0
fi

echo "==> notarizing (a few minutes)"
# --wait blocks until Apple returns a verdict. Without it the script exits while
# the submission is still in flight and stapling below fails confusingly.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling writes the ticket into the DMG so Gatekeeper can validate it without
# calling Apple. Only the DMG is stapled, not the .app inside it: stapling the
# app needs its own earlier notarization round-trip, and it only matters for a
# first launch with no network — which cannot happen here, because first launch
# downloads 633 MB of models before it can transcribe anything.
echo "==> stapling"
xcrun stapler staple "$DMG"

echo "==> verifying"
xcrun stapler validate "$DMG"
# What Gatekeeper actually runs on the customer's machine. `spctl -a` on a DMG
# checks the disk image itself; the app inside is checked on first launch.
spctl -a -t open --context context:primary-signature -v "$DMG"

rm -rf "$STAGE"

echo
echo "ready: $DMG"
echo "  commit:  $(git rev-parse --short HEAD)"
echo
echo "upload it to Gumroad, then tag the release:"
echo "  git tag -a v$VERSION -m 'v$VERSION' && git push origin v$VERSION"
