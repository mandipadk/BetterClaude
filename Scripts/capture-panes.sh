#!/bin/bash
# Captures each of the app's pillars for design review.
#
# Clicks are driven by window-relative coordinates rather than the accessibility API: AX
# element indices shift as panes expand their own content, and AX queries fail outright
# while the app is busy on the main thread. Window bounds are stable and always available.
set -uo pipefail

OUT="${1:?usage: capture-panes.sh <output-dir>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOWID_BIN=/tmp/bc-windowid
CLICK_BIN=/tmp/bc-click
[ -x "$WINDOWID_BIN" ] || swiftc -O "$ROOT/Scripts/windowid.swift" -o "$WINDOWID_BIN"
[ -x "$CLICK_BIN" ] || swiftc -O "$ROOT/Scripts/click.swift" -o "$CLICK_BIN"

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# Sidebar pillar rows, in points from the window's top-left.
CONVERSATIONS_Y=48
CONTROL_Y=88
LIBRARY_Y=128
SIDEBAR_X=110

bounds() { "$WINDOWID_BIN" "Better Claude" --bounds 2>/dev/null; }

click_in_window() {  # click_in_window <dx> <dy>
  local b x y
  b="$(bounds)" || return 1
  [ -z "$b" ] && return 1
  x=$(( $(echo "$b" | cut -d' ' -f1) + $1 ))
  y=$(( $(echo "$b" | cut -d' ' -f2) + $2 ))
  "$CLICK_BIN" "$x" "$y"
}

shot() {  # shot <name>
  local id
  osascript -e 'tell application "BetterClaude" to activate' >/dev/null 2>&1
  sleep 1
  id="$($WINDOWID_BIN "Better Claude" 2>/dev/null)"
  if [ -z "$id" ]; then echo "  ! no window for $1"; return 1; fi
  screencapture -x -o -l "$id" "$OUT/$1.png"
  echo "  captured $1"
}

pkill -f "BetterClaude.app" 2>/dev/null
sleep 1
open "$ROOT/dist/BetterClaude.app"
sleep 6
osascript -e 'tell application "BetterClaude" to activate' >/dev/null 2>&1
sleep 1

shot "01-conversations"

click_in_window "$SIDEBAR_X" "$CONTROL_Y"
sleep 5
shot "02-control"

click_in_window "$SIDEBAR_X" "$LIBRARY_Y"
# The first harvest reads several hundred megabytes.
sleep 20
shot "03-library"

# Select an artifact so the preview pane is exercised.
click_in_window 700 240
sleep 2
shot "04-library-preview"

click_in_window "$SIDEBAR_X" "$CONVERSATIONS_Y"
sleep 2

echo "Screens in $OUT"
ls -1 "$OUT"
