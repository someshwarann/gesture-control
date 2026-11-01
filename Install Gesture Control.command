#!/bin/bash
# Double-click this file to install Gesture Control.
cd "$(dirname "$0")"
echo "== Gesture Control installer =="
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Installing Apple's build tools. Click 'Install' in the popup, then double-click this file again when it finishes."
  xcode-select --install
  read -n 1 -s -r -p "Press any key to close…"
  exit 0
fi
chmod +x build.sh
./build.sh || { echo "Build failed. Copy the red text above and send it to Hark."; read -n 1 -s -r; exit 1; }
rm -rf "/Applications/Gesture Control.app"
mv "build/Gesture Control.app" /Applications/
open "/Applications/Gesture Control.app"
echo ""
echo "Done! Allow Camera + Accessibility when asked, then press Option+Command+G."
read -n 1 -s -r -p "Press any key to close…"
