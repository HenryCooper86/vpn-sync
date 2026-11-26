#!/bin/bash
# Builds "VPN Sync.app" and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/VPN Sync.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 \
	-o "$APP/Contents/MacOS/VPNSync" VPNSync.swift ServerViews.swift LiveMonitor.swift MenuBar.swift SettingsView.swift Theme.swift Icons.swift
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/lucide"
cp lucide/*.svg "$APP/Contents/Resources/lucide/"

swift make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
	sips -z $s $s build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
	sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset

# Sign with a stable identity so macOS remembers permissions (Desktop access, notifications)
# across rebuilds. Uses $VPNSYNC_SIGN_ID if set, else the first "Apple Development" or
# "Developer ID Application" certificate in the keychain, else ad hoc (permissions are then
# asked again after every rebuild).
SIGN_ID="${VPNSYNC_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
	SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
		| awk '/"(Apple Development|Developer ID Application):/ {print $2; exit}')
fi
if [ -n "$SIGN_ID" ]; then
	codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
	echo "signed with: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
	codesign --force --sign - "$APP"
	echo "warning: no signing certificate found; signed ad hoc (macOS will re-ask permissions after each rebuild)"
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/VPN Sync.app"
ditto "$APP" "$HOME/Applications/VPN Sync.app"
echo "installed: $HOME/Applications/VPN Sync.app"
