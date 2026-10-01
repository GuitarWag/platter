#!/bin/bash
# Build, package, and launch Platter as a proper macOS .app bundle.
# The window opens in the foreground with a Dock icon.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Platter.app"

# A running copy would keep the old build: `open` only brings it to the front. Quit it
# first (so it saves its state), and wait until it is gone before replacing the bundle.
if pgrep -x Platter >/dev/null; then
    osascript -e 'quit app id "local.platter"' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -x Platter >/dev/null || break; sleep 0.1; done
    pkill -x Platter 2>/dev/null || true
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/Platter "$APP/Contents/MacOS/Platter"

open "$APP"
echo "Launched ./Platter.app (Dock icon + foreground window)."
