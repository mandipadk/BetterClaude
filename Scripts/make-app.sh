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

# The version lives in one place (AppVersion.current); the build number counts commits, so
# every build of a later commit is a later build.
VERSION="$(sed -n 's/.*static let current = "\(.*\)"/\1/p' Sources/CoworkKit/Update/AppVersion.swift)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
[ -n "$VERSION" ] || { echo "error: no version in Sources/CoworkKit/Update/AppVersion.swift" >&2; exit 1; }

# Release builds are universal, so the same app runs on Apple silicon and Intel Macs.
ARCH_FLAGS=()
[ "$CONFIG" = "release" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "Building $VERSION ($BUILD, $CONFIG)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product BetterClaude
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product cowork
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product bc-recall

BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
# A debug build is a separate app with its own identity, so it never replaces the installed
# one or shares its preferences. Only debug builds honour BC_FIXTURE_ROOT and BC_UI_ROUTE.
if [ "$CONFIG" = "debug" ]; then
  APP="$ROOT/dist/debug/BetterClaude.app"
  BUNDLE_ID="com.betterclaude.app.debug"
  URL_SCHEME="betterclaude-debug"
else
  APP="$ROOT/dist/BetterClaude.app"
  BUNDLE_ID="com.betterclaude.app"
  URL_SCHEME="betterclaude"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Shortcuts and Siri find the app's actions from Metadata.appintents, which Xcode makes with
# appintentsmetadataprocessor. SwiftPM builds with Swift Build leave the compiler's constant
# values behind, so the same tool runs here. Older toolchains don't, and the app still works;
# the actions just don't appear.
INTENTS_WORK="$(mktemp -d)"
CONFIG_DIR="$([ "$CONFIG" = "release" ] && echo Release || echo Debug)"
find "$ROOT/.build/out/Intermediates.noindex/BetterClaude.build/$CONFIG_DIR/BetterClaude-p.build/Objects-normal/arm64" \
  -name '*.swiftconstvalues' > "$INTENTS_WORK/constvals.txt" 2>/dev/null || true
find "$ROOT/Sources/BetterClaude" -name '*.swift' > "$INTENTS_WORK/sources.txt"
if [ -s "$INTENTS_WORK/constvals.txt" ] && xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
    --module-name BetterClaude --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
    --source-file-list "$INTENTS_WORK/sources.txt" --swift-const-vals-list "$INTENTS_WORK/constvals.txt" >/dev/null 2>&1 \
    || echo "Shortcuts actions weren't described; the app works without them."
else
  echo "Shortcuts actions weren't described: no compiler constant values found."
fi
rm -rf "$INTENTS_WORK"

# Icon: an Icon Composer bundle generated from one geometry (Scripts/make-icon.swift), then
# compiled the way Xcode does, so the system draws its glass in every appearance, together
# with the accent colour. actool writes Assets.car and AppIcon.icns beside it.
ICON_BIN="${TMPDIR:-/tmp/}bc-icon"
ICON_WORK="$(mktemp -d)"
swiftc -O "$ROOT/Scripts/make-icon.swift" -o "$ICON_BIN"
"$ICON_BIN" "$ICON_WORK/AppIcon.icon"
"$ICON_BIN" --accent "$ICON_WORK/Assets.xcassets"
xcrun actool "$ICON_WORK/Assets.xcassets" "$ICON_WORK/AppIcon.icon" --compile "$APP/Contents/Resources" \
  --app-icon AppIcon --accent-color AccentColor \
  --platform macosx --minimum-deployment-target 26.0 \
  --output-partial-info-plist "$ICON_WORK/partial.plist" >/dev/null
rm -rf "$ICON_WORK"

cp "$BIN/BetterClaude" "$APP/Contents/MacOS/BetterClaude"
# Ship the CLI inside the bundle so the two can never drift apart in version.
cp "$BIN/cowork" "$APP/Contents/MacOS/cowork"
# The MCP server Claude talks to, registered from inside the bundle.
cp "$BIN/bc-recall" "$APP/Contents/MacOS/bc-recall"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Better Claude</string>
    <key>CFBundleDisplayName</key><string>Better Claude</string>
    <key>CFBundleExecutable</key><string>BetterClaude</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Every Claude conversation on your Mac, in one place.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array>
        </dict>
    </array>
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

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/cowork"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/bc-recall"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Built $APP $VERSION ($BUILD)"
echo
echo "  open $APP"
echo "  ln -sf \"$APP/Contents/MacOS/cowork\" ~/.local/bin/cowork   # optional CLI"
