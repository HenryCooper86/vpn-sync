# Shared settings for the vpn-sync server tools. Sourced, not executed.
# Layout is described by /etc/vpn-sync.conf (written by install.sh):
#   OVPN_DIR    folder holding openvpn-install.sh and the .ovpn client profiles
#   WG_DIR      folder holding wireguard-install.sh and the .conf client profiles
#   IKEV2_DIR   folder holding the IKEv2 client profiles (.mobileconfig, .sswan, .p12)
#   DNS_CHOICE  DNS menu answer used for new clients (3 = 1.1.1.1)
VPN_SYNC_CONF=${VPN_SYNC_CONF:-/etc/vpn-sync.conf}
# shellcheck disable=SC1090
[[ -f "$VPN_SYNC_CONF" ]] && . "$VPN_SYNC_CONF"
OVPN_DIR=${OVPN_DIR:-/root/vpn-setup}
WG_DIR=${WG_DIR:-/root/vpn-setup}
IKEV2_DIR=${IKEV2_DIR:-/root/vpn-setup/ikev2}
DNS_CHOICE=${DNS_CHOICE:-3}
LIB_DIR=${LIB_DIR:-/usr/local/lib/vpn-sync}
BACKUP_DIR=${BACKUP_DIR:-/root/vpn-sync-backups}
OVPN_SERVER_CONF=${OVPN_SERVER_CONF:-/etc/openvpn/server/server.conf}
OVPN_TEMPLATE=${OVPN_TEMPLATE:-/etc/openvpn/server/client-common.txt}
OVPN_PKI=${OVPN_PKI:-/etc/openvpn/server/easy-rsa/pki}
WG_CONF=${WG_CONF:-/etc/wireguard/wg0.conf}
# IPsec/IKEv2 from hwdsl2's setup-ipsec-vpn (Libreswan; certificates in the NSS database)
IKEV2_CONF=${IKEV2_CONF:-/etc/ipsec.d/ikev2.conf}
IKEV2_HELPER=${IKEV2_HELPER:-/opt/src/ikev2.sh}
IPSEC_DB=${IPSEC_DB:-sql:/etc/ipsec.d}
NAME_RE='^[A-Za-z0-9_-]{1,15}$'

have_openvpn()   { [[ -f "$OVPN_SERVER_CONF" && -f "$OVPN_DIR/openvpn-install.sh" ]]; }
have_wireguard() { [[ -f "$WG_CONF" && -f "$WG_DIR/wireguard-install.sh" ]]; }
have_ikev2()     { [[ -f "$IKEV2_CONF" && -f "$IKEV2_HELPER" ]]; }

# Client profile lists (skip backups and server configs)
ovpn_profiles() { local f; for f in "$OVPN_DIR"/*.ovpn; do [[ -f "$f" ]] && grep -q '^remote ' "$f" && echo "$f"; done; }
wg_profiles()   { local f; for f in "$WG_DIR"/*.conf; do [[ -f "$f" ]] && grep -q '^\[Peer\]' "$f" && grep -q '^Endpoint' "$f" && echo "$f"; done; }
ikev2_profiles() { local f; for f in "$IKEV2_DIR"/*.mobileconfig; do [[ -s "$f" ]] && echo "$f"; done; }

# ---- IKEv2 clients (hwdsl2's ikev2.sh helper)

# ikev2_has_client NAME: a client certificate with that name is in the IPsec database
ikev2_has_client() { certutil -L -d "$IPSEC_DB" -n "$1" >/dev/null 2>&1; }

# ikev2_helper ARGS...: run the helper so it writes client files to /root, not to the home
# of the user who ran sudo (it uses SUDO_USER's home when that is set)
ikev2_helper() { env -u SUDO_USER HOME=/root bash "$IKEV2_HELPER" "$@"; }

# ikev2_collect NAME: move NAME's exported files from /root into IKEV2_DIR (0600)
ikev2_collect() {
	local n="$1" ext
	install -d -m 700 "$IKEV2_DIR"
	for ext in mobileconfig sswan p12; do
		if [[ -f "/root/$n.$ext" ]]; then mv -f "/root/$n.$ext" "$IKEV2_DIR/$n.$ext"; chmod 600 "$IKEV2_DIR/$n.$ext"; fi
	done
	rm -f "/root/$n-README.txt"
	[[ -s "$IKEV2_DIR/$n.mobileconfig" ]]
}

# ikev2_sas: one line per connected IKEv2 tunnel (tab separated):
#   <name> <real ip> <vpn ip> <bytes rx> <bytes tx> <added epoch>
# from "ipsec trafficstatus" lines like
#   #3: "ikev2-cp"[1] 203.0.113.5, type=ESP, add_time=1700000000, inBytes=10, outBytes=20,
#       maxBytes=2^63B, id='O=IKEv2 VPN, CN=phone', lease=192.168.43.10/32
# (rx = from the device, tx = to it, as for OpenVPN and WireGuard)
ikev2_sas() {
	have_ikev2 && command -v ipsec >/dev/null || return 0
	ipsec trafficstatus 2>/dev/null | awk -v q="'" '
		function val(key,  r) { r = key "=[^, " q "]+"; if (match($0, r)) return substr($0, RSTART + length(key) + 1, RLENGTH - length(key) - 1); return "" }
		/ikev2-cp/ {
			name = val("CN"); if (name == "") next
			ip = ""; if (match($0, /\][ ]+[0-9A-Fa-f.:]+,/)) { ip = substr($0, RSTART + 1, RLENGTH - 2); gsub(/ /, "", ip) }
			lease = val("lease"); sub(/\/.*/, "", lease)
			printf "%s\t%s\t%s\t%.0f\t%.0f\t%.0f\n", name, (ip == "" ? "-" : ip), (lease == "" ? "-" : lease), val("inBytes"), val("outBytes"), val("add_time")
		}'
}

ensure_backup_dir() { mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"; }
require_root() { [[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 77; }; }
