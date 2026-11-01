#!/bin/bash
# Builds Gesture Control.app. Needs Xcode Command Line Tools: run  xcode-select --install  once.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Gesture Control.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/GestureControl" \
  -framework AppKit -framework AVFoundation -framework Vision \
  -framework Carbon -framework IOKit -framework ServiceManagement

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP"
echo "Move it to Applications and open it:"
echo "  mv \"$APP\" /Applications/ && open \"/Applications/Gesture Control.app\""
