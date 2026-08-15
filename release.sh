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

VERSION=$(grep -m1 '^VERSION=' build.sh | cut -d'"' -f2)
APP="build/Subtitles.app"
STAGE="build/dmg"
DMG="build/Subtitles-$VERSION.dmg"

echo "==> release $VERSION"

# Refuse to ship a dirty tree. The DMG is going to strangers who paid for it;
# "which commit was that build from" needs an answer.
if [ -n "$(git status --porcelain)" ]; then
  echo "!! working tree is dirty — commit or stash before releasing" >&2
  git status --short >&2
  exit 1
fi

./build.sh

# build.sh falls back to ad-hoc signing when the certificate is missing, and says
# so — but it says so in the middle of a lot of other output. Notarization would
# fail anyway; failing here explains why.
# -dvv, not -dv: the Authority lines only appear at the second v, and the guard
# silently never matches without it.
if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "!! $APP is not signed with a Developer ID — cannot notarize" >&2
  echo "   check: security find-identity -v -p codesigning" >&2
  exit 1
fi

echo "==> packaging $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The drag-to-install target. Without it the window is one icon and no hint of
# what to do with it.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Subtitles" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "    $(du -h "$DMG" | cut -f1)"

# The DMG is signed too. Otherwise Gatekeeper has nothing to check before the
# user has mounted anything, and the download looks unsigned at the worst moment.
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

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
