#!/bin/bash
# Measure CPU with both decks playing. Starts a second, silent copy of the app
# (PLATTER_BENCH=1: channel levels at zero), brings its window to the front for about
# 20 s, prints the average CPU, and quits it. `scripts/bench.sh hidden` keeps the
# window hidden (not drawn), which measures the audio side alone. A hidden window is not drawn, so the
# window must be visible for the number to mean anything.
set -e
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
PLATTER_BENCH=${1:-1} .build/release/Platter >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT
sleep 12
top -l 9 -s 2 -pid $pid -stats pid,cpu | awk -v p=$pid '$1 == p { print $2 }' | tail -8 |
    awk '{ s += $1; n++ } END { printf "average CPU: %.1f%% over %d samples\n", s / n, n }'
