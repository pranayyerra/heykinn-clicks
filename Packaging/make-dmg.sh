#!/bin/bash
#
# Wraps build/HeykinnClicks.app in a disk image somebody can be handed.
#
#   ./Packaging/make-dmg.sh                                    # from whatever is in build/
#   ./Packaging/make-dmg.sh --sign "Developer ID Application: Name (TEAMID)"
#   ./Packaging/make-dmg.sh --sign "…" --notarize heykinn      # …and notarise the image
#
# Run ./Packaging/bundle.sh --release --sign "…" first; this does not build.
#
# Why a disk image rather than the zip: a zip unpacks wherever it was
# downloaded, so the app gets run from Downloads, and every macOS release makes
# that a worse place to run something from. A disk image opens onto a window
# holding the app and a link to Applications, which is the one gesture everybody
# already knows.
#
# The image is signed and notarised in its own right. A notarised app inside an
# un-notarised image still warns on first open, because Gatekeeper judges the
# thing that was downloaded — and the thing that was downloaded is the .dmg.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY=""
PROFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sign)     IDENTITY="${2:?--sign needs an identity}"; shift 2 ;;
        --notarize) PROFILE="${2:?--notarize needs a keychain profile}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

APP="build/HeykinnClicks.app"
[ -d "$APP" ] || { echo "no app at $APP — run Packaging/bundle.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/HeykinnClicks-$VERSION.dmg"
STAGE="build/dmg-stage"

# The app is signed; the image inherits nothing from it, so refuse early rather
# than produce something that looks finished and warns on the far side.
if [ -n "$IDENTITY" ] && ! codesign --verify --strict "$APP" 2>/dev/null; then
    echo "The app in build/ is not validly signed. Re-run bundle.sh --sign first." >&2
    exit 1
fi

# The app gets its own ticket, before it goes into the image.
#
# Stapling only the .dmg leaves the app inside carrying nothing, so once
# somebody drags it to Applications and the image is gone, Gatekeeper has to
# reach Apple to check it. That works at a desk with a network and fails on a
# plane, behind a filter, or on a locked-down machine — the failure nobody can
# reproduce. Two submissions, and both artefacts answer for themselves.
if [ -n "$PROFILE" ]; then
    echo "Notarising the app…"
    APP_ZIP="build/HeykinnClicks-app.zip"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$APP_ZIP"
fi

echo "Staging…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto rather than cp: it preserves the signature's extended attributes, and a
# copy that quietly breaks the seal fails notarisation with a message about the
# app rather than about the copy.
ditto "$APP" "$STAGE/HeykinnClicks.app"
ln -s /Applications "$STAGE/Applications"

echo "Building $DMG…"
hdiutil create \
    -volname "Heykinn Clicks" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -quiet \
    "$DMG"
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
    echo "Signing the image…"
    # A secure timestamp, for the same reason bundle.sh asks for one: the notary
    # service refuses a signature without it.
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    codesign --verify --strict --verbose=1 "$DMG" 2>&1 | sed 's/^/  /'
fi

if [ -n "$PROFILE" ]; then
    echo "Notarising (this waits on Apple)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    # Stapled to the image itself, so it opens on a machine that is offline.
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
if [ -n "$PROFILE" ]; then
    echo "Verify what a downloader gets:"
    echo "  spctl -a -vvv -t open --context context:primary-signature $DMG"
else
    echo "Not notarised. Anyone else opening this will be warned by Gatekeeper;"
    echo "pass --sign and --notarize to produce one that will not be."
fi
