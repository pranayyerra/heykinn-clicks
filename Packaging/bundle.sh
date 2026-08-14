#!/bin/bash
#
# Assembles HeykinnClicks.app around the SwiftPM executable.
#
# The package builds a bare Mach-O binary. macOS will run it, and it mostly
# works — but an unbundled process has no bundle identifier, so it has no stable
# identity for the privacy system to hang a Photos grant on (today the grant
# belongs to whatever launched it, which is why it works under Xcode and would
# not on its own), and macOS logs a stream of failures registering it with the
# App Intents daemon and the process instance registry. This is the wrapper that
# fixes both.
#
#   ./Packaging/bundle.sh              debug build, ad-hoc signed
#   ./Packaging/bundle.sh --release    release build
#   ./Packaging/bundle.sh --release --sign "Developer ID Application: Name (TEAMID)"
#   ./Packaging/bundle.sh --release --build-number 153
#
# Notarisation is a separate step and is not done here; see PRODUCTION_READINESS.md.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
IDENTITY=""
ENTITLEMENTS="Packaging/HeykinnClicks.entitlements"
BUILD_NUMBER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --release) CONFIGURATION="release"; shift ;;
        --sign)    IDENTITY="${2:?--sign needs an identity}"; shift 2 ;;
        --adhoc)   IDENTITY="-"; shift ;;
        --build-number) BUILD_NUMBER="${2:?--build-number needs an integer}"; shift 2 ;;
        # The sandboxed build. Not a signing variant — it is a different app in
        # what it may touch, so it is worth being explicit about asking for it.
        --appstore) ENTITLEMENTS="Packaging/HeykinnClicks-AppStore.entitlements"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$BUILD_NUMBER" in
    "") ;;
    0|*[!0-9]*)
        echo "--build-number must be a positive integer" >&2
        exit 2
        ;;
esac

# Prefer a real identity, because macOS privacy permissions are keyed to one.
#
# Ad-hoc signing has no team identifier, so TCC — the thing behind System
# Settings → Privacy & Security — falls back to identifying the app by the hash
# of its code, which changes on *every* build. The effects are quiet and
# baffling: a permission granted to yesterday's build does not apply to today's,
# the app never appears in the Photos list at all, and "grant it in System
# Settings, then try again" sends somebody to a pane their app is not in.
#
# Any Apple Development certificate fixes it. Its team identifier is stable
# across rebuilds, so one grant survives them. Falls back to ad-hoc when there
# is no certificate, which still runs — it just cannot hold a permission.
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
    if [ -z "$IDENTITY" ]; then
        IDENTITY="-"
        echo "No Apple Development certificate found — signing ad-hoc."
        echo "  The app will run, but macOS cannot remember a Photos or"
        echo "  removable-volume permission across rebuilds."
    fi
fi

APP="build/HeykinnClicks.app"
BINARY=".build/${CONFIGURATION}/HeykinnClicks"

echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION"
[ -f "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/HeykinnClicks"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Default to the commit count so ordinary builds remain traceable. A release
# candidate made from reviewed but not-yet-committed changes can supply the
# next App Store Connect build number explicitly; reusing an already-uploaded
# number makes Transporter reject an otherwise valid package.
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null

# An icon is optional; without one macOS uses a generic placeholder.
if [ -f Packaging/AppIcon.icns ]; then
    cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# A provisioning profile, if one has been downloaded. It has to be inside the
# bundle *before* signing, under this exact name, or it is ignored — a rule
# worth automating rather than remembering, because the failure is an app that
# builds, signs, launches, and then quietly does not have the entitlements it
# claims. Download it from developer.apple.com and drop it in Packaging/;
# nothing else changes.
PROFILE_SOURCE=""
if [ "$ENTITLEMENTS" = "Packaging/HeykinnClicks-AppStore.entitlements" ] \
   && [ -f Packaging/HeykinnClicks-AppStore.provisionprofile ]; then
    PROFILE_SOURCE="Packaging/HeykinnClicks-AppStore.provisionprofile"
elif [ -f Packaging/HeykinnClicks.provisionprofile ]; then
    PROFILE_SOURCE="Packaging/HeykinnClicks.provisionprofile"
fi
if [ -n "$PROFILE_SOURCE" ]; then
    cp "$PROFILE_SOURCE" "$APP/Contents/embedded.provisionprofile"
    echo "Embedded $(basename "$PROFILE_SOURCE")"
fi

echo "Signing (identity: $IDENTITY)…"
# A secure timestamp for anything but ad-hoc. Notarisation refuses a signature
# without one — "The signature does not include a secure timestamp" — and it is
# the kind of refusal that costs an upload and a wait to discover. Ad-hoc keeps
# --timestamp=none: it cannot be notarised anyway, and asking Apple's timestamp
# authority puts a network round trip in the middle of every local build.
TIMESTAMP="--timestamp"
[ "$IDENTITY" = "-" ] && TIMESTAMP="--timestamp=none"

# Hardened runtime always: it costs nothing here and notarisation requires it,
# so a debug bundle that differs from the shipped one in this respect would
# hide exactly the problems worth finding early.
codesign --force --sign "$IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    $TIMESTAMP \
    "$APP"

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# What the signed binary actually carries, rather than what the file on disk
# asked for. An entitlement can be requested and not granted — an app group
# without a matching profile is the usual way — and the result is an app that
# builds, signs, launches, and behaves as though it never asked. Reported here
# because the alternative is finding out from a user.
echo
echo "Entitlements in the signed binary:"
EFFECTIVE_PLIST="$(mktemp -t heykinn-entitlements).plist"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert xml1 -o "$EFFECTIVE_PLIST" - 2>/dev/null || true

# The *value*, not merely the key. The Developer ID build sets app-sandbox to
# false and it is present either way, so reporting presence would tick the box
# on a build that is not sandboxed at all — the one thing this report exists to
# tell apart.
SANDBOX="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$EFFECTIVE_PLIST" 2>/dev/null || echo absent)"
case "$SANDBOX" in
    true)  echo "  ✓ sandboxed (App Store build)" ;;
    false) echo "  · not sandboxed (Developer ID build)" ;;
    *)     echo "  · app-sandbox absent" ;;
esac

# The one that cost a day. It is a Hardened Runtime entitlement as much as a
# sandbox one, and without it macOS refuses the Photos library silently — no
# prompt, and the app never appears under Privacy & Security → Photos. It never
# showed up in development because `swift run` has no hardened runtime.
PHOTOS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.photos-library' "$EFFECTIVE_PLIST" 2>/dev/null || echo absent)"
if [ "$PHOTOS" = "true" ]; then
    echo "  ✓ Photos library access"
else
    echo "  ✗ Photos library access MISSING — connecting Photos will be refused with no prompt"
fi

GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$EFFECTIVE_PLIST" 2>/dev/null || echo "")"
if [ -n "$GROUP" ]; then
    echo "  ✓ app group $GROUP — shares one archive with the other build"
else
    echo "  · no app group — this build would keep an archive of its own"
fi
rm -f "$EFFECTIVE_PLIST"
if [ -f "$APP/Contents/embedded.provisionprofile" ]; then
    echo "  ✓ embedded.provisionprofile"
else
    echo "  · no provisioning profile embedded"
fi

echo
echo "Built $APP"
echo "  bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
echo "  version:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($BUILD_NUMBER)"
echo
echo "Run it:   open $APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Note: ad-hoc signed, so this bundle runs on this Mac only. For anyone"
    echo "else it needs a Developer ID signature and notarisation."
fi
