#!/bin/bash
# Build, package, and launch Platter as a proper macOS .app bundle.
# The window opens in the foreground with a Dock icon.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Platter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/Platter "$APP/Contents/MacOS/Platter"

open "$APP"
echo "Launched ./Platter.app (Dock icon + foreground window)."
