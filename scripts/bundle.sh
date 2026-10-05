#!/bin/sh
# Builds dist/ClaudeHUD.app (universal arm64 + x86_64) with the hook scripts inside.
#   scripts/bundle.sh [version]
set -e
cd "$(dirname "$0")/.."
VERSION=${1:-0.0.0-dev}
APP=dist/ClaudeHUD.app

swift build -c release --arch arm64 --arch x86_64
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/ClaudeHUD "$APP/Contents/MacOS/"
cp hooks/*.sh scripts/setup-hooks.sh "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.louay.claudehud</string>
  <key>CFBundleName</key><string>Claude HUD</string>
  <key>CFBundleExecutable</key><string>ClaudeHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Set CODESIGN_ID to your own "Apple Development: …" identity so macOS keeps the Accessibility
# grant across rebuilds; otherwise the app is ad-hoc signed.
if [ -n "$CODESIGN_ID" ]; then codesign -s "$CODESIGN_ID" -f "$APP"; else codesign -s - -f "$APP"; fi
echo "Built $APP ($VERSION)"
