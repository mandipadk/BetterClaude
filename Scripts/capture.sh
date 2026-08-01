#!/bin/bash
# Captures the app's key screens for design review.
#
# Crops to the app window rather than the whole display: a full-screen grab pulls in
# whatever else is on the desktop, which both distracts a reviewer and captures unrelated
# windows that are nobody's business.
set -uo pipefail

OUT="${1:?usage: capture.sh <output-dir>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$OUT"
rm -f "$OUT"/*.png

WINDOWID_BIN=/tmp/bc-windowid
[ -x "$WINDOWID_BIN" ] || swiftc -O "$ROOT/Scripts/windowid.swift" -o "$WINDOWID_BIN"

shot() {  # shot <name>
  local id
  id="$($WINDOWID_BIN "Better Claude" 2>/dev/null)"
  if [ -z "$id" ]; then echo "  ! no BetterClaude window found for $1"; return 1; fi
  # -l captures the window's own backing store, so an occluding window cannot leak in.
  screencapture -x -o -l "$id" "$OUT/$1.png"
  echo "  captured $1 (window $id)"
}

pkill -f "BetterClaude.app" 2>/dev/null
sleep 1
open "$ROOT/dist/BetterClaude.app"
sleep 5

osascript -e 'tell application "System Events" to tell process "BetterClaude" to set frontmost to true' >/dev/null 2>&1
sleep 1
shot "01-main"

# Select a row and open the transfer sheet.
osascript <<'EOF' >/dev/null 2>&1
tell application "System Events" to tell process "BetterClaude"
  set detail to group 1 of window 1
  perform action "AXPress" of (UI element 1 of UI element 1 of scroll area 2 of detail)
  delay 0.6
  perform action "AXPress" of (last button of detail)
end tell
EOF
sleep 2
shot "02-transfer-configure"

# Advance to the review step so its layout is reviewable too.
osascript <<'EOF' >/dev/null 2>&1
tell application "System Events" to tell process "BetterClaude"
  -- Footer order is Cancel then the primary action, so the last button is "Review".
  perform action "AXPress" of (last button of group 1 of sheet 1 of window 1)
end tell
EOF
sleep 14
shot "03-transfer-review"

osascript -e 'tell application "System Events" to tell process "BetterClaude" to keystroke return' >/dev/null 2>&1
sleep 1
pkill -f "BetterClaude.app" 2>/dev/null

echo "Screens in $OUT"
ls -1 "$OUT"
