#!/bin/bash
# Installs vpn-sync on this Mac: the command, the server bundle it uploads, and the app.
set -euo pipefail
cd "$(dirname "$0")"
install -d "$HOME/.local/bin" "$HOME/.local/share/vpn-sync"
install -m 755 vpn-sync "$HOME/.local/bin/vpn-sync"
rm -rf "$HOME/.local/share/vpn-sync/server"
cp -R server "$HOME/.local/share/vpn-sync/server"
chmod 755 "$HOME/.local/share/vpn-sync/server/install.sh" "$HOME/.local/share/vpn-sync/server/bin/"* \
	"$HOME/.local/share/vpn-sync/server/lib/"*.exp
echo "installed: ~/.local/bin/vpn-sync and ~/.local/share/vpn-sync/server"
if [ "${1:-}" != "--no-app" ]; then ./app/build.sh; fi
