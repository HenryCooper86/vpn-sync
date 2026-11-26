# Shared settings for the vpn-sync server tools. Sourced, not executed.
# Layout is described by /etc/vpn-sync.conf (written by install.sh):
#   OVPN_DIR    folder holding openvpn-install.sh and the .ovpn client profiles
#   WG_DIR      folder holding wireguard-install.sh and the .conf client profiles
#   DNS_CHOICE  DNS menu answer used for new clients (3 = 1.1.1.1)
VPN_SYNC_CONF=${VPN_SYNC_CONF:-/etc/vpn-sync.conf}
# shellcheck disable=SC1090
[[ -f "$VPN_SYNC_CONF" ]] && . "$VPN_SYNC_CONF"
OVPN_DIR=${OVPN_DIR:-/root/vpn-setup}
WG_DIR=${WG_DIR:-/root/vpn-setup}
DNS_CHOICE=${DNS_CHOICE:-3}
LIB_DIR=${LIB_DIR:-/usr/local/lib/vpn-sync}
BACKUP_DIR=${BACKUP_DIR:-/root/vpn-sync-backups}
OVPN_SERVER_CONF=${OVPN_SERVER_CONF:-/etc/openvpn/server/server.conf}
OVPN_TEMPLATE=${OVPN_TEMPLATE:-/etc/openvpn/server/client-common.txt}
OVPN_PKI=${OVPN_PKI:-/etc/openvpn/server/easy-rsa/pki}
WG_CONF=${WG_CONF:-/etc/wireguard/wg0.conf}
NAME_RE='^[A-Za-z0-9_-]{1,15}$'

have_openvpn()   { [[ -f "$OVPN_SERVER_CONF" && -f "$OVPN_DIR/openvpn-install.sh" ]]; }
have_wireguard() { [[ -f "$WG_CONF" && -f "$WG_DIR/wireguard-install.sh" ]]; }

# Client profile lists (skip backups and server configs)
ovpn_profiles() { local f; for f in "$OVPN_DIR"/*.ovpn; do [[ -f "$f" ]] && grep -q '^remote ' "$f" && echo "$f"; done; }
wg_profiles()   { local f; for f in "$WG_DIR"/*.conf; do [[ -f "$f" ]] && grep -q '^\[Peer\]' "$f" && grep -q '^Endpoint' "$f" && echo "$f"; done; }

ensure_backup_dir() { mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"; }
require_root() { [[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 77; }; }
