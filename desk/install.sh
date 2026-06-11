#!/bin/bash
# VibeNotch installer — builds a Release .app and installs it to /Applications.
# Existing hooks in ~/.vibenotch/ and ~/.claude/settings.json are untouched;
# the new app uses the same absolute paths.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "→ Generating Xcode project…"
xcodegen generate >/dev/null

echo "→ Building Release configuration (this can take a minute)…"
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

echo "→ Stopping any running VibeNotch instance…"
pkill -f "VibeNotch.app/Contents/MacOS/VibeNotch" 2>/dev/null || true
sleep 1

echo "→ Installing to /Applications/VibeNotch.app…"
rm -rf /Applications/VibeNotch.app
cp -R "$BUILT_APP" /Applications/VibeNotch.app

echo "→ Launching the installed copy…"
open /Applications/VibeNotch.app

echo ""
echo "✓ Installed. The app is now running from /Applications/VibeNotch.app"
echo ""
echo "To make it auto-start at login:"
echo "  System Settings → General → Login Items & Extensions"
echo "    → click + under 'Open at Login' → pick VibeNotch"
echo ""
echo "To uninstall:"
echo "  bash ~/.vibenotch/uninstall.sh   # removes hook entries"
echo "  rm -rf /Applications/VibeNotch.app"
echo "  rm -rf ~/.vibenotch              # removes scripts + flag"
