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
# A debug build is a separate app with its own identity, so it never replaces the installed
# one or shares its preferences. Only debug builds honour BC_FIXTURE_ROOT and BC_UI_ROUTE.
if [ "$CONFIG" = "debug" ]; then
  APP="$ROOT/dist/debug/BetterClaude.app"
  BUNDLE_ID="com.betterclaude.app.debug"
else
  APP="$ROOT/dist/BetterClaude.app"
  BUNDLE_ID="com.betterclaude.app"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$(dirname "$APP")/BetterClaude.iconset"

# Icon: generated rather than checked in, so the mark stays tied to the palette in
# Theme.swift and every size is redrawn from the same geometry.
ICON_BIN=/tmp/bc-icon
swiftc -O "$ROOT/Scripts/make-icon.swift" -o "$ICON_BIN"
rm -rf "$ICONSET"
"$ICON_BIN" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/BetterClaude.icns"

cp "$BIN/BetterClaude" "$APP/Contents/MacOS/BetterClaude"
# Ship the CLI inside the bundle so the two can never drift apart in version.
cp "$BIN/cowork" "$APP/Contents/MacOS/cowork"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Better Claude</string>
    <key>CFBundleDisplayName</key><string>Better Claude</string>
    <key>CFBundleExecutable</key><string>BetterClaude</string>
    <key>CFBundleIconFile</key><string>BetterClaude</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- The classic full-height sidebar and one frosted window surface, rather than
         macOS 26's floating inset sidebar. -->
    <key>UIDesignRequiresCompatibility</key><true/>
    <key>NSHumanReadableCopyright</key><string>Every Claude conversation on your Mac, in one place.</string>
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
