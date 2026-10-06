#!/bin/zsh
# Captures the README screenshots into docs/images/ from the Release build and the synthesised demo.
# Usage: scripts/screenshots.sh   (needs Screen Recording permission for your terminal)
# Demo media is copied to $TMPDIR first: reading a file on ~/Desktop or ~/Documents by path would make
# macOS ask the app for folder access (files chosen in the Open panel or dropped are fine).
set -e
cd "$(dirname "$0")/.."
APP="build/Build/Products/Release/Spectrogram Studio.app"
[[ -x build/make_demo ]] || swiftc -O scripts/make_demo.swift -o build/make_demo
[[ -x build/window_id ]] || swiftc -O scripts/window_id.swift -o build/window_id
DEMO="${TMPDIR:-/tmp}/SpectrogramStudioDemo"
[[ -f "$DEMO/Demo Melody.mp4" ]] || build/make_demo "$DEMO"

capture() {   # capture <name> <seconds to wait> <launch args...>
  local name=$1 wait=$2; shift 2
  pkill -x "Spectrogram Studio" 2>/dev/null || true; sleep 1
  open -n "$APP" --args "$@"
  sleep $wait
  local wid=$(build/window_id)
  [[ -n $wid ]] || { echo "no window for $name"; return; }
  screencapture -x -o -l"$wid" "docs/images/$name.png"
  sips -s format jpeg -s formatOptions 82 -Z 1600 "docs/images/$name.png" --out "docs/images/$name.jpg" >/dev/null
  rm "docs/images/$name.png"
  echo "captured $name"
}

capture main 12 -openFile "$DEMO/Demo Melody.mp4" -demoStrokes YES -seekTo 3.7
capture unpainted 12 -openFile "$DEMO/Demo Melody.wav" -seekTo 1.6
capture empty 12
pkill -x "Spectrogram Studio" 2>/dev/null || true
