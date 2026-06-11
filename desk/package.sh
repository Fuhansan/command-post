#!/bin/bash
# VibeNotch packager — produces a shareable .zip and .dmg of the Release build.
# Recipients only need the .dmg/.zip; they never see the source code.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

OUT_DIR="$PROJECT_DIR/dist"
mkdir -p "$OUT_DIR"

echo "→ Generating Xcode project…"
xcodegen generate >/dev/null

echo "→ Building Release configuration…"
xcodebuild \
  -project VibeNotch.xcodeproj \
  -scheme VibeNotch \
  -configuration Release \
  -derivedDataPath "$PROJECT_DIR/.build" \
  build 2>&1 | tail -5

BUILT_APP="$PROJECT_DIR/.build/Build/Products/Release/VibeNotch.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "✗ Build product not found at $BUILT_APP"
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
ZIP_PATH="$OUT_DIR/VibeNotch-${VERSION}.zip"
DMG_PATH="$OUT_DIR/VibeNotch-${VERSION}.dmg"

echo "→ Zipping .app → $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$ZIP_PATH"

echo "→ Building .dmg → $DMG_PATH"
rm -f "$DMG_PATH"
STAGE_DIR=$(mktemp -d)
cp -R "$BUILT_APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create \
  -volname "VibeNotch" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$STAGE_DIR"

echo ""
echo "✓ Packaged:"
ls -lh "$ZIP_PATH" "$DMG_PATH" | awk '{print "    " $9 "  (" $5 ")"}'
echo ""
echo "Share either file. Recipients should:"
echo "  • Open the .dmg → drag VibeNotch to Applications, OR"
echo "  • Unzip and move VibeNotch.app to Applications"
echo "  • First launch: right-click → Open → confirm (ad-hoc signed, Gatekeeper will warn once)"
echo "  • The app self-installs hooks into ~/.claude/settings.json on first launch"
