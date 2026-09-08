#!/bin/bash
# Builds, packages, notarizes and staples a DMG, and publishes the release.
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
# [main-edition]
#   - the Sparkle signing key in the login keychain (PLAN.md §23) — the one
#     whose public half is SPARKLE_PUBLIC_KEY in build.sh
#   - `gh`, logged in, for the GitHub release the update is served from
#
# The GitHub release is the download. Three assets: the DMG under the stable
# name Subtitles.dmg, which the site's download button points at through
# releases/latest/download/; the zip Sparkle installs from; and the appcast,
# which GitHub likewise serves newest-first and the site proxies /appcast.xml
# to with one rule in its _redirects — so the app keeps asking
# subtitles-live.com, and nothing on the site changes per release. The
# release is created as a draft and published only once every asset is up, so
# no check can see an appcast whose archive is still uploading, and no button
# a release whose DMG is not there yet.
# [/main-edition]
set -euo pipefail

cd "$(dirname "$0")"
PROFILE="${SUBTITLES_NOTARY_PROFILE:-subtitles-notary}"

# --no-notarize builds the DMG and stops. Notarization is a three-minute round
# trip to Apple and irrelevant to how the window looks, which is the thing that
# actually needs iterating on. The result is NOT shippable.
NOTARIZE=yes
# [main-edition]
# --critical marks the update as one every copy should take now: the app shows
# its window at once rather than waiting for a quiet moment, and offers no
# Skip. For the fix nobody should sit out — the reason this updater exists
# (PLAN.md §23) — and for nothing else.
CRITICAL=no
# --dry-run exercises the publishing half without publishing: no notarization,
# no tag, a draft release that is deleted again at the end. What it proves is
# that the appcast generates, signs and uploads, and that the assets are the
# ones expected — everything that cannot be undone once a real release is out.
DRYRUN=no
# [/main-edition]
# [0bsd-edition]
# DRYRUN=no
# [/0bsd-edition]
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=no ;;
    # [main-edition]
    --critical) CRITICAL=yes ;;
    --dry-run) DRYRUN=yes; NOTARIZE=no ;;
    *) echo "usage: release.sh [--no-notarize | --dry-run] [--critical]" >&2; exit 1 ;;
    # [/main-edition]
    # [0bsd-edition]
    # *) echo "usage: release.sh [--no-notarize]" >&2; exit 1 ;;
    # [/0bsd-edition]
  esac
done

VERSION=$(grep -m1 '^VERSION=' build.sh | cut -d'"' -f2)
APP="build/Subtitles.app"
STAGE="build/dmg"
DMG="build/Subtitles-$VERSION.dmg"
RWDMG="build/Subtitles-rw.dmg"
# [main-edition]
# The same file under the name that never changes, for the release. The
# versioned one stays for Gumroad's product page and for the shelf in build/.
STABLE_DMG="build/Subtitles.dmg"
# What Sparkle installs. A zip rather than the DMG: Sparkle can update from
# either, but a DMG has to be mounted first and this is the one everybody's
# machine fetches.
ZIP="build/Subtitles-$VERSION.zip"
# Where the appcast is assembled. The previous one comes down from the latest
# release first, so entries accumulate; the site holds no copy.
FEED_DIR="build/feed"
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
REPO="daformat/subtitles"
RELEASES="https://github.com/$REPO/releases"
# What every installed copy asks, daily. The site proxies it to GitHub.
FEED_URL=$(grep -m1 '^SPARKLE_FEED=' build.sh | cut -d'"' -f2)
TAG="v$VERSION"
# [/main-edition]

echo "==> release $VERSION"

# [main-edition]
# Everything the tail of this script needs, checked before the three-minute
# notarization round trip rather than after it.
if [ "$NOTARIZE" = yes ] || [ "$DRYRUN" = yes ]; then
  command -v gh >/dev/null || { echo "!! gh is not installed" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "!! gh is not logged in" >&2; exit 1; }
  # A version with no notes is not one to ship; this exits 1 and says so.
  tools/changelog-notes.py "$VERSION" >/dev/null
  if [ "$DRYRUN" = no ] && git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "!! $TAG is already tagged — bump VERSION and BUILD in build.sh" >&2; exit 1
  fi
  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "!! a release $TAG already exists on GitHub (a leftover draft, perhaps):" >&2
    echo "   gh release delete $TAG -R $REPO --yes" >&2; exit 1
  fi
fi
# [/main-edition]

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
# the stale-volume guard above. Unquoted heredoc so it interpolates, which means
# the script below must contain no $, backslash or backtick of its own — not even
# inside an AppleScript comment, which the shell reads long before osascript does.
VOLNAME=$(basename "$MOUNT")

if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 428, not 400: "bounds" covers the whole window including the title bar,
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

if [ "$NOTARIZE" = no ] && [ "$DRYRUN" = no ]; then
  rm -rf "$STAGE"
  echo
  echo "built $DMG — NOT notarized, do not ship this one"
  echo "open it to check the window:  open $DMG"
  exit 0
fi

if [ "$DRYRUN" = no ]; then
  echo "==> notarizing (a few minutes)"
  # --wait blocks until Apple returns a verdict. Without it the script exits
  # while the submission is still in flight and stapling below fails
  # confusingly.
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

  # Stapling writes the ticket into the DMG so Gatekeeper can validate it
  # without calling Apple. The app inside is stapled too, below, for the zip.
  echo "==> stapling"
  xcrun stapler staple "$DMG"

  echo "==> verifying"
  xcrun stapler validate "$DMG"
  # What Gatekeeper actually runs on the customer's machine. `spctl -a` on a
  # DMG checks the disk image itself; the app inside is checked on first launch.
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

rm -rf "$STAGE"

# [main-edition]
# The update archive (PLAN.md §23). The app is stapled first: the DMG's ticket
# covers the app inside it, so this needs no second round trip, and it means
# the copy Sparkle installs carries its own proof rather than relying on the
# network for it.
echo "==> update archive"
[ "$DRYRUN" = no ] && xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "    $(du -h "$ZIP" | cut -f1)"

# The appcast. generate_appcast signs the new archive with the Keychain key,
# adds an entry for it, and keeps the entries already in the file — which is
# why the previous release's copy is brought down first. Release notes are the
# CHANGELOG entry, rendered beside the archive under the same name, so the
# update window and the GitHub release say the same thing.
echo "==> appcast"
[ -x "$GENERATE_APPCAST" ] || { echo "!! $GENERATE_APPCAST missing — run swift build" >&2; exit 1; }
rm -rf "$FEED_DIR"; mkdir -p "$FEED_DIR"
cp "$ZIP" "$FEED_DIR/"
tools/changelog-notes.py "$VERSION" --html > "$FEED_DIR/Subtitles-$VERSION.html"
# The first release has nothing to download, and gh says so; that is the one
# failure allowed here.
if gh release download -R "$REPO" -p appcast.xml -D "$FEED_DIR" 2>/dev/null; then
  echo "    previous appcast: $(grep -c '<item>' "$FEED_DIR/appcast.xml") entries"
else
  echo "    no previous release — starting a fresh appcast"
fi
APPCAST_FLAGS=()
# An empty version means critical from any version, which is the only kind
# of critical this app has.
[ "$CRITICAL" = yes ] && APPCAST_FLAGS+=(--critical-update-version "")
# The odd expansion is for the bash macOS ships (3.2), where an empty array
# counts as unset under `set -u` and "${ARR[@]}" aborts the script.
"$GENERATE_APPCAST" \
  --download-url-prefix "$RELEASES/download/v$VERSION/" \
  --link "https://subtitles-live.com" \
  --embed-release-notes \
  ${APPCAST_FLAGS[@]+"${APPCAST_FLAGS[@]}"} \
  "$FEED_DIR"
grep -q "sparkle:version>$(grep -m1 '^BUILD=' build.sh | cut -d'"' -f2)<" "$FEED_DIR/appcast.xml" \
  || { echo "!! appcast has no entry for this build" >&2; exit 1; }

# The GitHub release. A draft first, with every asset on it, published only
# once they are all up: a check that lands between the appcast appearing and
# its zip finishing would otherwise be offered a download that 404s.
#
# The DMG is on it since 1.6, as Subtitles.dmg. Through 1.5 it was kept off:
# the DMG was the product Gumroad sold, and a release page is a download page
# for anyone who finds it. With the trial (PLAN.md §24) the DMG is a free
# download and the key is the product, so the release is the right place for
# it — GitHub's release assets have no bandwidth cap, which Netlify's would
# eventually feel — and the stable name is what lets the site's button point
# at releases/latest/download/Subtitles.dmg for good.
#
# The tag is made here rather than by hand afterwards, because the appcast
# points at a URL with the tag's name in it, and a tag typed differently is a
# 404 on every machine.
NOTES="build/notes-$VERSION.md"
tools/changelog-notes.py "$VERSION" > "$NOTES"
cp "$DMG" "$STABLE_DMG"
if [ "$DRYRUN" = no ]; then
  echo "==> tagging $TAG"
  git tag -a "$TAG" -m "$TAG"
  git push origin "$TAG"
fi
echo "==> github release $TAG (draft)"
gh release create "$TAG" -R "$REPO" --draft --target "$(git rev-parse HEAD)" \
  --title "Subtitles $VERSION" --notes-file "$NOTES" \
  "$STABLE_DMG" "$ZIP" "$FEED_DIR/appcast.xml"
# Every asset, by name, before anything is published. Uploads fail quietly
# often enough that this is worth ten lines.
ASSETS=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')
for want in "$(basename "$STABLE_DMG")" "$(basename "$ZIP")" appcast.xml; do
  grep -qx "$want" <<<"$ASSETS" || { echo "!! asset missing from the draft: $want" >&2; exit 1; }
done
echo "    assets: $(tr '\n' ' ' <<<"$ASSETS")"

if [ "$DRYRUN" = yes ]; then
  gh release delete "$TAG" -R "$REPO" --yes
  echo
  echo "dry run complete: the draft was created with all three assets and deleted again."
  echo "  $DMG is NOT notarized — do not ship this one"
  exit 0
fi

echo "==> publishing"
gh release edit "$TAG" -R "$REPO" --draft=false --latest

# What every installed copy will see. The site proxies /appcast.xml to the
# latest release's asset; GitHub takes a moment to point "latest" at the new
# release, so this waits a little before calling it a failure.
echo "==> checking the feed"
BUILD=$(grep -m1 '^BUILD=' build.sh | cut -d'"' -f2)
for attempt in $(seq 1 12); do
  if curl -fsSL "$FEED_URL" | grep -q "sparkle:version>$BUILD<"; then
    echo "    $FEED_URL offers build $BUILD"
    break
  fi
  [ "$attempt" = 12 ] && {
    echo "!! $FEED_URL does not offer build $BUILD yet." >&2
    echo "   The release is published; either GitHub is slow to update 'latest'," >&2
    echo "   or the site's _redirects rule for /appcast.xml is not deployed." >&2
    echo "   Check: curl -sL $RELEASES/latest/download/appcast.xml | grep sparkle:version" >&2
    exit 1
  }
  sleep 5
done

echo
echo "ready: $DMG"
echo "  commit:   $(git rev-parse --short HEAD)"
echo "  release:  $RELEASES/tag/$TAG"
echo "  download: $RELEASES/latest/download/Subtitles.dmg — what the site's button serves now"
echo "  feed:     $FEED_URL — live, every copy that checks is offered $VERSION"
echo
echo "upload $DMG to Gumroad's product page too, for the receipt's link."
# [/main-edition]
# [0bsd-edition]
# echo
# echo "ready: $DMG"
# echo "  commit:  $(git rev-parse --short HEAD)"
# echo
# echo "tag the release:"
# echo "  git tag -a v$VERSION -m 'v$VERSION' && git push origin v$VERSION"
# [/0bsd-edition]
