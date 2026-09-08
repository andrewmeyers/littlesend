#!/bin/bash
# Builds LittleSend and installs it into /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
DESTINATION="${1:-/Applications}"

./Scripts/build-app.sh release

if [ ! -w "$DESTINATION" ]; then
    echo "error: $DESTINATION is not writable by $(whoami)." >&2
    echo "Drag build/LittleSend.app there in Finder instead." >&2
    exit 1
fi

# Quit any running copy so the bundle can be replaced cleanly.
if pgrep -f "LittleSend.app/Contents/MacOS/LittleSend" >/dev/null; then
    echo "Quitting the running copy…"
    pkill -f "LittleSend.app/Contents/MacOS/LittleSend" || true
    sleep 1
fi

rm -rf "$DESTINATION/LittleSend.app"
cp -R build/LittleSend.app "$DESTINATION/LittleSend.app"

echo "Installed $DESTINATION/LittleSend.app"
echo
echo "Open it from Spotlight (⌘-Space, \"LittleSend\") or Launchpad."
echo "To start it at login: System Settings → General → Login Items → +"
