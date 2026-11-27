#!/bin/bash
# Runs the Mac app on made-up servers and devices (for screenshots, or to look around without
# a server). Builds vpn-sync-demo, makes a demo home in /tmp, and opens the app with it.
# Your real servers, settings and notifications aren't touched: the app is started with
# VPNSYNC_HOME pointing at the demo home, notifications off, and the first demo server selected.
#   demo/run-mac-demo.sh [extra environment, e.g. VPNSYNC_TAB=traffic]
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO_HOME="${DEMO_HOME:-${TMPDIR:-/tmp}/vpn-sync-demo-home}"
mkdir -p demo/build
swiftc -swift-version 5 -O -o demo/build/vpn-sync-demo demo/main.swift shared/DemoData.swift
rm -rf "$DEMO_HOME"
demo/build/vpn-sync-demo setup "$DEMO_HOME"
APP="$HOME/Applications/VPN Sync.app"
pkill -f "VPN Sync.app/Contents/MacOS/VPNSync" 2>/dev/null || true
sleep 1
envs=(--env "VPNSYNC_HOME=$DEMO_HOME")
for e in "$@"; do envs+=(--env "$e"); done
open -g "${envs[@]}" "$APP" --args -selectedServer Tokyo -notify '<false/>' -limitAlerts '<false/>' -monitoring '<true/>'
sleep 3
open -g "$APP"   # brings up the main window
echo "VPN Sync is running on demo data from $DEMO_HOME. Quit it and open it normally to go back."
