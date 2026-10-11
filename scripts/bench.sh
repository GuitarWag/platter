#!/bin/bash
# Measure CPU while music plays. Starts a second, silent copy of an app, brings its window
# to the front for about 20 s, prints the average CPU, and quits it. A hidden window is not
# drawn, so the window must be visible for the number to mean anything.
#   scripts/bench.sh            Platter (DJ rig), both decks, channel levels at zero
#   scripts/bench.sh hidden     the same with the window hidden: the audio side alone
#   scripts/bench.sh player N   Platter Player at volume 0; visualizer N: 0 spectrum, 1 scope, 2 off
# A benchmark saves no play history, queue, or settings.
set -e
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
if [ "$1" = "player" ]; then
    exe=PlatterPlayer; bench=1; viz=${2:-0}
else
    exe=Platter; bench=${1:-1}; viz=0
fi
PLATTER_BENCH=$bench PLATTER_BENCH_VIZ=$viz ".build/release/$exe" >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT
sleep 12
top -l 9 -s 2 -pid $pid -stats pid,cpu | awk -v p=$pid '$1 == p { print $2 }' | tail -8 |
    awk '{ s += $1; n++ } END { printf "average CPU: %.1f%% over %d samples\n", s / n, n }'
