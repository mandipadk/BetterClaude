#!/bin/bash
# Assembles BetterClaude.app from the SwiftPM build products.
#
# The app is deliberately NOT sandboxed: it reads Claude Desktop's data directories, which a
# sandboxed app cannot reach without the user picking each one in an open panel. Those paths
# are not in a TCC-protected category, so a plain non-sandboxed binary reads them with no
# permission prompt and without Full Disk Access.
#
# Ad-hoc signing is sufficient for local use. A locally built bundle never acquires the
# com.apple.quarantine attribute, so Gatekeeper does not consult its assessment and the app
# launches with no "unidentified developer" dialog. Distributing it to another Mac would
# require a Developer ID signature and notarization.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product BetterClaude
swift build -c "$CONFIG" --product cowork

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/BetterClaude.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Icon: generated rather than checked in, so the mark stays tied to the palette in
# Design.swift and every size is redrawn from the same geometry.
ICON_BIN=/tmp/bc-icon
swiftc -O "$ROOT/Scripts/make-icon.swift" -o "$ICON_BIN"
rm -rf "$ROOT/dist/BetterClaude.iconset"
"$ICON_BIN" "$ROOT/dist/BetterClaude.iconset"
iconutil -c icns "$ROOT/dist/BetterClaude.iconset" -o "$APP/Contents/Resources/BetterClaude.icns"

cp "$BIN/BetterClaude" "$APP/Contents/MacOS/BetterClaude"
# Ship the CLI inside the bundle so the two can never drift apart in version.
cp "$BIN/cowork" "$APP/Contents/MacOS/cowork"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Better Claude</string>
    <key>CFBundleDisplayName</key><string>Better Claude</string>
    <key>CFBundleExecutable</key><string>BetterClaude</string>
    <key>CFBundleIconFile</key><string>BetterClaude</string>
    <key>CFBundleIdentifier</key><string>com.betterclaude.app</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Transfers Claude Cowork conversations between installs.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Claude Conversation Bundle</string>
            <key>CFBundleTypeExtensions</key><array><string>coworkbundle</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSTypeIsPackage</key><true/>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "Built $APP"
echo
echo "  open $APP"
echo "  ln -sf \"$APP/Contents/MacOS/cowork\" ~/.local/bin/cowork   # optional CLI"
