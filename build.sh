#!/bin/bash
# Builds MailPrint.app into ~/Applications.
# Needs the Xcode Command Line Tools (run `xcode-select --install` once if swiftc is missing).
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/MailPrint.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/MailPrint" MailPrint.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.mailprint</string>
  <key>CFBundleName</key><string>MailPrint</string>
  <key>CFBundleExecutable</key><string>MailPrint</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>MailPrint reads the selected message from Mail so it can print it with its attachments.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
