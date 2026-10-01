#!/bin/bash
# Photographs the app's screens for design review, from a sample Mac.
#
#   Scripts/capture.sh <output-dir> [route ...]
#
# Builds a debug app, builds a sample Mac with invented conversations (bc-fixture), and opens
# each screen straight from a route (BC_UI_ROUTE) in light and dark. No real conversation is
# ever on screen, and nothing clicks: the mouse and keyboard stay yours while it runs.
# `screencapture -l` grabs the window's own backing store, so other windows never leak in.
# ACTIVATE=1 brings each window to the front first, so prominent buttons draw as they do in
# use (inactive windows draw them grey). It takes keyboard focus while it runs.
set -uo pipefail

OUT="${1:?usage: capture.sh <output-dir> [route ...]}"
shift
ROUTES=("$@")
if [ ${#ROUTES[@]} -eq 0 ]; then
  ROUTES=("conversations" "reader:Lisbon" "reader:webhook" "reader:standing desks"
          "reader:flaky upload" "install:Claude Work" "install:Claude Code" "messages:backoff")
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; pkill -f "dist/debug/BetterClaude.app" 2>/dev/null' EXIT
mkdir -p "$OUT"

[ -n "${SKIP_BUILD:-}" ] || bash "$ROOT/Scripts/make-app.sh" debug >/dev/null
swift build --package-path "$ROOT" --product bc-fixture >/dev/null
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
"$BIN/bc-fixture" "$WORK/mac" >/dev/null
swiftc -O "$ROOT/Scripts/windowid.swift" -o "$WORK/windowid"

APP="$ROOT/dist/debug/BetterClaude.app/Contents/MacOS/BetterClaude"
for route in "${ROUTES[@]}"; do
  for appearance in light dark; do
    name="$(echo "$route" | tr ':/ ' '---' | tr -cd '[:alnum:]-')-$appearance"
    if [ -n "${ACTIVATE:-}" ]; then
      # Through Launch Services, which brings the app to the front; a process started from a
      # shell can't take focus on its own.
      open -n --env BC_FIXTURE_ROOT="$WORK/mac" --env BC_UI_ROUTE="$route" --env BC_APPEARANCE="$appearance" \
        "$ROOT/dist/debug/BetterClaude.app"
      sleep 1
      pid="$(pgrep -n -f "dist/debug/BetterClaude.app/Contents/MacOS/BetterClaude")"
    else
      BC_FIXTURE_ROOT="$WORK/mac" BC_UI_ROUTE="$route" BC_APPEARANCE="$appearance" "$APP" >/dev/null 2>&1 &
      pid=$!
    fi
    sleep "${SETTLE:-3}"
    id="$("$WORK/windowid" "Better Claude" --pid "$pid" 2>/dev/null)"
    if [ -n "$id" ]; then
      screencapture -x -o -l "$id" "$OUT/$name.png" && echo "  $name"
    else
      echo "  ! no window for $name"
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
  done
done
