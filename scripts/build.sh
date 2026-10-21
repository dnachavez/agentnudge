#!/bin/bash
# Builds build/AgentNudge.app and build/AgentNudge-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.9.0}"
TARGET="arm64-apple-macos14"
BUILD="build"
APP="$BUILD/AgentNudge.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling app"
swiftc -O -swift-version 5 -target "$TARGET" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  Sources/App/*.swift -o "$APP/Contents/MacOS/AgentNudge"

echo "Compiling hook helper"
swiftc -O -swift-version 5 -target "$TARGET" \
  Sources/Hook/main.swift -o "$APP/Contents/MacOS/agentnudge-hook"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "Compiling icon"
# The Icon Composer bundle becomes Assets.car (layered Liquid Glass icon, macOS 26) plus
# AgentNudge.icns (flattened, for earlier macOS).
# actool needs absolute paths: given relative ones, its icon export fails and it still exits 0.
# Icon Composer files need Xcode 26; without it the app builds with the generic icon.
xcrun actool "$PWD/Resources/AgentNudge.icon" --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AgentNudge \
  --output-partial-info-plist "$PWD/$BUILD/icon-info.plist" >/dev/null 2>&1 || true
[ -f "$APP/Contents/Resources/Assets.car" ] || echo "Note: no icon compiled (needs Xcode 26); building without it." >&2

echo "Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/MacOS/agentnudge-hook"
codesign --force --sign - "$APP"

echo "Packaging DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "AgentNudge" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/AgentNudge-$VERSION.dmg"
rm -rf "$STAGE"

echo "Done: $APP"
echo "      $BUILD/AgentNudge-$VERSION.dmg"
