#!/bin/bash
# Packages an already-built BetterClaude.app into a distributable disk image.
#
# Usage: Scripts/make-dmg.sh [path/to/BetterClaude.app]
#        (defaults to dist/BetterClaude.app — run Scripts/make-app.sh first)
#
# The version in the output filename is read from the bundle's Info.plist rather than
# hardcoded here, so the dmg can never claim a version the app does not report.
#
# Uses only tools present on a stock macOS install: hdiutil, ditto, osascript, shasum.
# No Homebrew, no create-dmg.
#
# The image is not signed and the app inside is only ad-hoc signed. A dmg downloaded
# through a browser carries com.apple.quarantine, so Gatekeeper will refuse the first
# launch and the user has to right-click -> Open. See Scripts/RELEASING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/BetterClaude.app}"
VOLNAME="Better Claude"
MOUNT="/Volumes/$VOLNAME"

die() { echo "make-dmg: $*" >&2; exit 1; }

[ -d "$APP" ] || die "no app bundle at $APP — run Scripts/make-app.sh release first"
[ -f "$APP/Contents/Info.plist" ] || die "$APP has no Contents/Info.plist — not an app bundle"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VERSION" ] || die "could not read CFBundleShortVersionString from $APP/Contents/Info.plist"

DIST="$ROOT/dist"
STAGE="$DIST/.dmg-stage"
RW_DMG="$DIST/.BetterClaude-rw.dmg"
OUT="$DIST/BetterClaude-$VERSION.dmg"

# Detach anything left mounted by an interrupted earlier run, otherwise hdiutil attach
# renames the volume to "Better Claude 1" and the Finder script targets the wrong disk.
detach_stale() {
    local dev
    # Any device currently serving our volume name, plus anything backed by our scratch image.
    while read -r dev; do
        [ -n "$dev" ] || continue
        echo "make-dmg: detaching stale mount $dev"
        hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    done < <(
        {
            hdiutil info | awk -v v="$MOUNT" '$0 ~ ("\t" v "$") || $NF == v { print $1 }'
            hdiutil info | awk -v img="$RW_DMG" '
                /^image-path/ { keep = ($NF == img) }
                keep && /^\/dev\/disk/ { print $1 }'
        } | sort -u
    )
    if [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    fi
}

cleanup() {
    detach_stale
    rm -rf "$STAGE" "$RW_DMG"
}
trap cleanup EXIT

detach_stale
rm -rf "$STAGE" "$RW_DMG"
mkdir -p "$STAGE"

# ditto (not cp) so the code signature, symlinks and extended attributes survive the copy.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

# Give the mounted volume the app's own icon, when the bundle has one. Optional: the flag
# that activates it needs SetFile from the Xcode command line tools, which the CI runner has
# but a machine with no developer tools does not.
ICNS="$(ls "$APP/Contents/Resources/"*.icns 2>/dev/null | head -1 || true)"
if [ -n "$ICNS" ]; then
    cp "$ICNS" "$STAGE/.VolumeIcon.icns"
fi

# Size the writable image with slack: the Finder needs room to write .DS_Store, and an
# image sized exactly to its contents fails to mount read-write on some macOS versions.
SIZE_KB=$(( $(du -sk "$STAGE" | awk '{print $1}') + 40000 ))

echo "make-dmg: creating writable image (${SIZE_KB}k)…"
hdiutil create \
    -srcfolder "$STAGE" \
    -volname "$VOLNAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -ov -quiet \
    "$RW_DMG" || die "hdiutil create failed"

echo "make-dmg: attaching…"
DEV="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -nobrowse \
        | awk '/^\/dev\// { dev = $1 } END { print dev }')" \
    || die "hdiutil attach failed"
[ -n "$DEV" ] || die "hdiutil attach returned no device"
[ -d "$MOUNT" ] || die "image attached as $DEV but did not mount at $MOUNT"

# kHasCustomIcon on the volume root is what makes .VolumeIcon.icns take effect.
if [ -f "$MOUNT/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT" || echo "make-dmg: warning — could not set the custom volume icon flag" >&2
fi

# Window geometry and icon placement, written into the volume's .DS_Store by the Finder.
#
# This needs a Finder that will answer Apple events for a mounted volume. In a headless or
# automation-restricted session (CI, ssh, a sandboxed agent) the Finder accepts the connection
# but never replies, so each statement would otherwise block for the two-minute default
# AppleEvent timeout. Both an in-script `with timeout` and an outer watchdog bound that.
#
# The layout is cosmetic: without it the volume still contains the app and the /Applications
# symlink, just arranged by the Finder's defaults. So a failure here warns and continues.
style_window() {
    osascript <<APPLESCRIPT >/dev/null 2>&1
with timeout of 20 seconds
    tell application "Finder"
        tell disk "$VOLNAME"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 140, 800, 540}
            set opts to the icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 96
            set text size of opts to 12
            set position of item "BetterClaude.app" of container window to {150, 170}
            set position of item "Applications" of container window to {450, 170}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end timeout
APPLESCRIPT
}

# A layout captured earlier beats asking the Finder, because the Finder will refuse in every
# environment that matters: CI has no logged-in session, and a local run needs the terminal to
# hold an Automation grant for Finder. Without this the window layout is never applied
# anywhere, which makes style_window decorative rather than functional.
#
# To produce the template: run this script once on a Mac where the Finder does answer (grant
# the terminal Automation → Finder in System Settings → Privacy & Security), then
#   cp /Volumes/Better\ Claude/.DS_Store Scripts/dmg-DS_Store
# before it detaches, and commit that file.
TEMPLATE="$ROOT/Scripts/dmg-DS_Store"
if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$MOUNT/.DS_Store"
    echo "make-dmg: applied the committed window layout"
    STYLE_PID=""
    STYLE_OK=1
else

style_window & STYLE_PID=$!
STYLE_OK=1
for _ in $(seq 1 60); do
    kill -0 "$STYLE_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$STYLE_PID" 2>/dev/null; then
    pkill -9 -P "$STYLE_PID" 2>/dev/null || true
    kill -9 "$STYLE_PID" 2>/dev/null || true
    wait "$STYLE_PID" 2>/dev/null || true
    STYLE_OK=0
else
    wait "$STYLE_PID" || STYLE_OK=0
fi
if [ "$STYLE_OK" -eq 0 ]; then
    echo "make-dmg: warning — the Finder would not accept the layout script;" >&2
    echo "make-dmg:           the dmg is valid but uses default icon positions." >&2
    echo "make-dmg:           See the Scripts/dmg-DS_Store note above to fix this once." >&2
fi

fi

sync
echo "make-dmg: detaching…"
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$DEV" >/dev/null 2>&1; then
        DEV=""
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        hdiutil detach "$DEV" -force >/dev/null 2>&1 || die "could not detach $DEV"
        DEV=""
        break
    fi
    sleep 2
done

echo "make-dmg: compressing…"
rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet \
    || die "hdiutil convert failed"

hdiutil verify "$OUT" >/dev/null 2>&1 || die "the finished image failed hdiutil verify"

SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"

echo
echo "Built $OUT"
echo "  version : $VERSION"
echo "  size    : $(du -h "$OUT" | awk '{print $1}')"
echo "  sha256  : $SHA"
echo
echo "Not notarised — a browser download will be quarantined and Gatekeeper will block"
echo "the first launch. Users must right-click the app and choose Open once."
