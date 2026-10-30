#!/bin/bash
# Builds FakeBattery.app. Requires Xcode or the Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP="FakeBattery.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/FakeBattery" main.swift \
  -framework Cocoa -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>FakeBattery</string>
  <key>CFBundleIdentifier</key><string>com.local.FakeBattery</string>
  <key>CFBundleName</key><string>FakeBattery</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP - run: open $APP"
