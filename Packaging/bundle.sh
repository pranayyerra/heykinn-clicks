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
#
# Notarisation is a separate step and is not done here; see PRODUCTION_READINESS.md.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
IDENTITY="-"                       # ad-hoc: runs on this Mac, nowhere else
while [ $# -gt 0 ]; do
    case "$1" in
        --release) CONFIGURATION="release"; shift ;;
        --sign)    IDENTITY="${2:?--sign needs an identity}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

APP="build/HeykinnClicks.app"
BINARY=".build/${CONFIGURATION}/HeykinnClicks"

echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION"
[ -f "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/HeykinnClicks"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Version from the current commit, so a build can always be traced back to one.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null

# An icon is optional; without one macOS uses a generic placeholder.
if [ -f Packaging/AppIcon.icns ]; then
    cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

echo "Signing (identity: $IDENTITY)…"
# Hardened runtime always: it costs nothing here and notarisation requires it,
# so a debug bundle that differs from the shipped one in this respect would
# hide exactly the problems worth finding early.
codesign --force --sign "$IDENTITY" \
    --options runtime \
    --entitlements Packaging/HeykinnClicks.entitlements \
    --timestamp=none \
    "$APP"

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

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
