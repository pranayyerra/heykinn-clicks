#!/bin/bash
#
# Builds the installer package the Mac App Store takes.
#
#   ./Packaging/make-pkg.sh --sign "3rd Party Mac Developer Installer: Name (TEAMID)"
#
# Run this after:
#   ./Packaging/bundle.sh --release --appstore --sign "Apple Distribution: Name (TEAMID)"
#
# Two different certificates are involved and they are easy to confuse:
#
#   Apple Distribution              signs the .app
#   3rd Party Mac Developer Installer   signs the .pkg      ← this one
#
# Having the first and not the second is the ordinary situation, because the
# first is what Xcode creates for you and the second has to be asked for.
#
# The upload itself is not done here. Apple's own tools want either Transporter
# (free, from the Mac App Store) or an app-specific password on the command
# line, and this script deliberately handles no credentials.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) IDENTITY="${2:?--sign needs an installer identity}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

APP="build/HeykinnClicks.app"
[ -d "$APP" ] || { echo "no app at $APP — run bundle.sh --appstore first" >&2; exit 1; }

# Refuse early rather than produce a package the Store will reject after an
# upload and a wait. An unsandboxed app cannot go to the App Store at all, and
# the mistake is one flag away: bundle.sh without --appstore.
ENTITLEMENTS_PLIST="$(mktemp -t heykinn-pkg).plist"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert xml1 -o "$ENTITLEMENTS_PLIST" - 2>/dev/null || true
SANDBOXED="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_PLIST" 2>/dev/null || echo false)"
rm -f "$ENTITLEMENTS_PLIST"
if [ "$SANDBOXED" != "true" ]; then
    echo "The app in build/ is not sandboxed, so the App Store will not take it." >&2
    echo "Rebuild with:  ./Packaging/bundle.sh --release --appstore --sign \"Apple Distribution: …\"" >&2
    exit 1
fi

# The identifier has to be *in the signature*, not only in the profile. Xcode
# injects it; signing by hand with an explicit entitlements file does not, and
# the upload is rejected after the fact — "the signature for the bundle is
# missing an application identifier but has an application identifier in the
# provisioning profile" (error 90886). Compared here against the profile,
# because a mismatch is rejected the same way as an absence.
SIG_PLIST="$(mktemp -t heykinn-sig).plist"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert xml1 -o "$SIG_PLIST" - 2>/dev/null || true
SIGNED_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$SIG_PLIST" 2>/dev/null || echo "")"
rm -f "$SIG_PLIST"

if [ -z "$SIGNED_ID" ]; then
    echo "The signature carries no application identifier, and the upload will be rejected (90886)." >&2
    echo "Add to Packaging/HeykinnClicks-AppStore.entitlements:" >&2
    echo "  com.apple.application-identifier = <TEAMID>.<bundle id>" >&2
    echo "  com.apple.developer.team-identifier = <TEAMID>" >&2
    exit 1
fi

if [ -f "$APP/Contents/embedded.provisionprofile" ]; then
    PROF_PLIST="$(mktemp -t heykinn-prof).plist"
    security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$PROF_PLIST" 2>/dev/null || true
    PROFILE_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROF_PLIST" 2>/dev/null || echo "")"
    rm -f "$PROF_PLIST"
    if [ -n "$PROFILE_ID" ] && [ "$SIGNED_ID" != "$PROFILE_ID" ]; then
        echo "The signature and the profile name different apps, and the upload will be rejected." >&2
        echo "  signature: $SIGNED_ID" >&2
        echo "  profile:   $PROFILE_ID" >&2
        exit 1
    fi
fi

# Keys the App Store refuses. `codesign` signs whatever it is handed, so an
# entitlement that does not exist is accepted locally, does nothing, and is
# rejected on upload with "entitlements that are not supported on macOS"
# (90285). Grown by hand as each one is met — there is no list to check against.
for bad in com.apple.security.device.removable-volumes; do
    if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "$bad"; then
        echo "The signature carries '$bad', which the App Store rejects (90285)." >&2
        echo "Remove it from Packaging/HeykinnClicks-AppStore.entitlements." >&2
        exit 1
    fi
done

if [ ! -f "$APP/Contents/embedded.provisionprofile" ]; then
    echo "No provisioning profile is embedded, and App Store Connect will reject the upload." >&2
    echo "Download one carrying the app group and drop it in as:" >&2
    echo "  Packaging/HeykinnClicks-AppStore.provisionprofile" >&2
    echo "then re-run bundle.sh --appstore. See Packaging/README.md." >&2
    exit 1
fi

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v 2>/dev/null \
        | sed -n 's/.*"\(3rd Party Mac Developer Installer:[^"]*\)".*/\1/p' | head -1)
    if [ -z "$IDENTITY" ]; then
        echo "No installer certificate found." >&2
        echo "Create one: Xcode → Settings → Accounts → Manage Certificates → + →" >&2
        echo "  Mac Installer Distribution" >&2
        echo "It is a different certificate from the Apple Distribution one that signs the app." >&2
        exit 1
    fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
# Include the build number so the package used for TestFlight and the one used
# for the recording cannot be confused with an older binary carrying the same
# marketing version.
PKG="build/HeykinnClicks-$VERSION-$BUILD_NUMBER.pkg"

echo "Building ${PKG}…"
rm -f "$PKG"
# --component rather than a component plist: one app, installed to /Applications.
productbuild \
    --component "$APP" /Applications \
    --sign "$IDENTITY" \
    "$PKG"

echo
echo "Built $PKG"
echo "  app version: $VERSION ($BUILD_NUMBER)"
echo
echo "Upload it with Transporter (free, from the Mac App Store): drag $PKG in."
echo "The app record has to exist in App Store Connect first, with this bundle id:"
echo "  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
