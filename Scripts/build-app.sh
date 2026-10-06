#!/bin/bash
# Assembles LittleSend.app from the SwiftPM executable.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
APP="build/LittleSend.app"

echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/LittleSend"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/LittleSend"
cp Support/Info.plist "$APP/Contents/Info.plist"

# The local reader's Readability script has to travel with the app. It goes in
# Contents/Resources, which is where Bundle.main looks; SwiftPM's own
# Bundle.module accessor is no use here, since it searches beside the bundle
# root and otherwise a .build path that only exists on the build machine.
cp Sources/LittleSendCore/Resources/Readability.js "$APP/Contents/Resources/Readability.js"
echo "Bundled Readability.js"

# The icon is an Icon Composer bundle. actool turns it into Assets.car, which
# macOS 26 draws with Liquid Glass and its dark and tinted looks, plus
# LittleSend.icns for macOS 14 and 15. Info.plist names both
# (CFBundleIconName and CFBundleIconFile). Paths are absolute because actool
# does not resolve relative ones against this script's directory.
ICON_TMP="$(mktemp -d)"
xcrun actool "$PWD/Support/LittleSend.icon" \
    --compile "$PWD/$APP/Contents/Resources" \
    --app-icon LittleSend \
    --platform macosx --target-device mac \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$ICON_TMP/partial.plist" \
    --errors --warnings >/dev/null
rm -rf "$ICON_TMP"
echo "Compiled app icon"

# Sign with a real certificate when there is one. Its identity (team and
# bundle ID) stays the same from build to build, so a keychain "Always Allow" —
# for WebKit's "LittleSend WebCrypto Master Key", say — sticks. An ad-hoc
# signature is tied to the exact bytes of this build, so every rebuild looks
# like a new app to the keychain and it asks again.
#
# Override with SIGN_IDENTITY="…"; a free "Apple Development" certificate from
# Xcode → Settings → Accounts is enough for this.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development)' | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)}"
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 \
        && echo "Signed with $SIGN_IDENTITY" \
        || echo "warning: could not sign with $SIGN_IDENTITY"
else
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
        && echo "Signed ad hoc — keychain prompts will return after each rebuild" \
        || echo "warning: could not codesign"
fi

echo "Built $APP"
echo "Run it with:  open $APP"
