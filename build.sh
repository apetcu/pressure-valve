#!/bin/zsh
# Builds Pressure Valve.app and installs it into ~/Applications.
set -euo pipefail
cd "${0:A:h}"
APP="build/Pressure Valve.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Model.swift Views.swift Demo.swift main.swift -o "$APP/Contents/MacOS/PressureValve"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pressure Valve</string>
  <key>CFBundleDisplayName</key><string>Pressure Valve</string>
  <key>CFBundleIdentifier</key><string>org.apetcu.PressureValve</string>
  <key>CFBundleExecutable</key><string>PressureValve</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

# Quit a running copy, then install and launch.
osascript -e 'tell application id "org.apetcu.PressureValve" to quit' 2>/dev/null || true
sleep 1
mkdir -p ~/Applications
ditto "$APP" ~/Applications/"Pressure Valve.app"
open ~/Applications/"Pressure Valve.app"
echo "Installed ~/Applications/Pressure Valve.app"
