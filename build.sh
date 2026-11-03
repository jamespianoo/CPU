#!/bin/bash
# Builds CPU.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"
APP=CPU.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -o $APP/Contents/MacOS/CPU main.swift
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CPU</string>
<key>CFBundleDisplayName</key><string>CPU</string>
<key>CFBundleIdentifier</key><string>com.cpumonitor.menubar</string>
<key>CFBundleExecutable</key><string>CPU</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - $APP
pkill -x CPU 2>/dev/null || true
rm -rf /Applications/$APP
cp -R $APP /Applications/$APP
echo "Installed /Applications/$APP"
