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

# Ad-hoc signature: enough for a personal build, and it gives the app a stable
# identity so the Keychain stops re-prompting on every launch.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "warning: could not codesign; the Keychain may prompt on each launch"

echo "Built $APP"
echo "Run it with:  open $APP"
