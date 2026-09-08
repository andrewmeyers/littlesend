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

# Ad-hoc signature: enough for a personal build, and it gives the app a stable
# identity so the Keychain stops re-prompting on every launch.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "warning: could not codesign; the Keychain may prompt on each launch"

echo "Built $APP"
echo "Run it with:  open $APP"
