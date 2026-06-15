#!/bin/bash
# VibeNotch installer — builds a Release .app and installs it to /Applications.
# Existing hooks in ~/.vibenotch/ and ~/.claude/settings.json are untouched;
# the new app uses the same absolute paths.
set -e
set -o pipefail   # xcodebuild 失败时不被 tail 吞掉退出码

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

# 用固定的本地自签名证书重签名:签名身份稳定 → 辅助功能等 TCC 授权
# 跨构建持续有效(ad-hoc 签名每次构建都变,导致每次重装都要重新授权)。
SIGN_ID="VibeNotch Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "→ Code signing with '$SIGN_ID'…"
  codesign --force --deep -s "$SIGN_ID" /Applications/VibeNotch.app
else
  echo "⚠ 未找到 '$SIGN_ID' 证书,保持 ad-hoc 签名(每次重装需重新授权辅助功能)"
fi

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
