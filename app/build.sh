#!/bin/bash
# Builds "VPN Sync.app" and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/VPN Sync.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 \
	-o "$APP/Contents/MacOS/VPNSync" VPNSync.swift ServerViews.swift LiveMonitor.swift MenuBar.swift
cp Info.plist "$APP/Contents/Info.plist"

swift make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
	sips -z $s $s build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
	sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset

codesign --force --sign - "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/VPN Sync.app"
ditto "$APP" "$HOME/Applications/VPN Sync.app"
echo "installed: $HOME/Applications/VPN Sync.app"
