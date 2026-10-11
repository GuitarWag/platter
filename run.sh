#!/bin/bash
# Build both apps, package them as macOS .app bundles, and open one.
#   ./run.sh          builds both, opens Platter (the DJ rig)
#   ./run.sh player   builds both, opens Platter Player
# Both apps share one library and audio store in ~/Library/Application Support/Platter.
set -e
cd "$(dirname "$0")"

swift build -c release

# package <bundle dir> <executable> <plist> <bundle id>
package() {
    local app="$1" exe="$2" plist="$3" id="$4"
    # A running copy would keep the old build: `open` only brings it to the front. Quit it
    # first (so it saves its state), and wait until it is gone before replacing the bundle.
    if pgrep -x "$exe" >/dev/null; then
        osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
        for _ in $(seq 1 50); do pgrep -x "$exe" >/dev/null || break; sleep 0.1; done
        pkill -x "$exe" 2>/dev/null || true
    fi
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$plist" "$app/Contents/Info.plist"
    cp ".build/release/$exe" "$app/Contents/MacOS/$exe"
}

package "Platter.app" Platter bundles/Platter.plist local.platter
package "Platter Player.app" PlatterPlayer bundles/PlatterPlayer.plist local.platter.player

if [ "$1" = "player" ]; then
    open "Platter Player.app"
    echo "Launched ./Platter Player.app"
else
    open "Platter.app"
    echo "Launched ./Platter.app (run ./run.sh player for the music player)"
fi
