#!/usr/bin/env bash
# install.sh — set up a server for vpn-sync. Run as root from the unpacked bundle.
#
# - Installs the vpn-sync tools (and expect, qrencode, curl).
# - OpenVPN / WireGuard already installed (Nyr or compatible): keeps them as they are
#   and only records where their client profiles live.
# - Not installed: installs them with Nyr's road-warrior scripts using the options below.
#
# Usage: install.sh [--public-ip IP] [--openvpn-proto tcp|udp] [--openvpn-port N]
#                   [--wireguard-port N] [--dns N] [--client NAME]
#                   [--no-openvpn] [--no-wireguard]
#   --dns: Nyr menu number: 1 system, 2 Google, 3 1.1.1.1 (default), 4 OpenDNS, 5 Quad9,
#          6 Gcore, 7 AdGuard
# Prints "SETUP_OK" as its last line on success.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

OVPN_URL=https://raw.githubusercontent.com/Nyr/openvpn-install/master/openvpn-install.sh
WG_URL=https://raw.githubusercontent.com/Nyr/wireguard-install/master/wireguard-install.sh

public_ip="" ovpn_proto=tcp ovpn_port=443 wg_port=443 dns=3 client=client want_ovpn=1 want_wg=1
while [[ $# -gt 0 ]]; do
	case "$1" in
		--public-ip) public_ip="$2"; shift ;;
		--openvpn-proto) ovpn_proto="$2"; shift ;;
		--openvpn-port) ovpn_port="$2"; shift ;;
		--wireguard-port) wg_port="$2"; shift ;;
		--dns) dns="$2"; shift ;;
		--client) client="$2"; shift ;;
		--no-openvpn) want_ovpn=0 ;;
		--no-wireguard) want_wg=0 ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 64 ;;
	esac
	shift
done

say() { echo "==> $*"; }
die() { echo "!! $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run as root"
[[ "$ovpn_proto" == tcp || "$ovpn_proto" == udp ]] || die "--openvpn-proto must be tcp or udp"
for p in "$ovpn_port" "$wg_port"; do [[ "$p" =~ ^[0-9]+$ && $p -ge 1 && $p -le 65535 ]] || die "bad port: $p"; done
[[ "$dns" =~ ^[1-7]$ ]] || die "--dns must be 1-7"
[[ "$client" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || die "--client: use 1-15 letters, digits, _ or -"

# ---- 1. packages
say "Installing helper packages (expect, qrencode, curl, vnstat)"
if command -v apt-get >/dev/null; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq expect qrencode curl vnstat >/dev/null
elif command -v dnf >/dev/null; then
	dnf install -y -q expect curl >/dev/null
	dnf install -y -q vnstat >/dev/null 2>&1 || true
	dnf install -y -q qrencode >/dev/null 2>&1 || { dnf install -y -q epel-release >/dev/null && dnf install -y -q qrencode >/dev/null; }
else
	die "unsupported system: need apt-get or dnf (Ubuntu, Debian, AlmaLinux, Rocky, CentOS, Fedora)"
fi

# ---- 2. tools
say "Installing vpn-sync tools"
install -d -m 755 /usr/local/lib/vpn-sync
install -m 644 "$here/lib/common.sh" /usr/local/lib/vpn-sync/
install -m 755 "$here"/lib/*.exp /usr/local/lib/vpn-sync/
install -m 755 "$here"/bin/* /usr/local/sbin/
install -m 644 "$here"/systemd/vpn-endpoint-sync.service "$here"/systemd/vpn-endpoint-sync.timer /etc/systemd/system/

# ---- 3. existing layout, if any
OVPN_DIR="" WG_DIR="" DNS_CHOICE="$dns"
# shellcheck disable=SC1091
[[ -f /etc/vpn-sync.conf ]] && . /etc/vpn-sync.conf
find_script() { # find_script <file>: folder holding a Nyr script, if any
	local d f
	for d in /root/vpn-setup /root/openvpn-setup /root/wireguard-setup /root; do
		[[ -f "$d/$1" ]] && { echo "$d"; return 0; }
	done
	f=$(find /root /home /opt -maxdepth 3 -type f -name "$1" 2>/dev/null | head -n 1)
	[[ -n "$f" ]] && dirname "$f"
	return 0
}
fetch() { curl -fsSL -o "$2" "$1" && chmod 700 "$2"; }

if [[ -z "$public_ip" ]]; then
	public_ip=$(curl -4 -fsS -m 10 https://checkip.amazonaws.com | tr -d '[:space:]') || die "could not detect the public IP; pass --public-ip"
fi

# ---- 4. OpenVPN
if [[ -f /etc/openvpn/server/server.conf ]]; then
	[[ -n "$OVPN_DIR" && -f "$OVPN_DIR/openvpn-install.sh" ]] || OVPN_DIR=$(find_script openvpn-install.sh)
	if [[ -z "$OVPN_DIR" ]]; then
		OVPN_DIR=/root/vpn-setup; install -d -m 700 "$OVPN_DIR"
		fetch "$OVPN_URL" "$OVPN_DIR/openvpn-install.sh"
	fi
	say "OpenVPN already installed ($(grep -E '^(proto|port) ' /etc/openvpn/server/server.conf | awk '{print $2}' | paste -sd ' ' -)); keeping it. Profiles: $OVPN_DIR"
	echo "RESULT_OPENVPN=existing"
elif [[ $want_ovpn -eq 1 ]]; then
	OVPN_DIR=/root/vpn-setup; install -d -m 700 "$OVPN_DIR"
	say "Installing OpenVPN ($ovpn_proto $ovpn_port) with Nyr's openvpn-install"
	fetch "$OVPN_URL" "$OVPN_DIR/openvpn-install.sh"
	proto_choice=1; [[ "$ovpn_proto" == tcp ]] && proto_choice=2
	/usr/local/lib/vpn-sync/nyr-answer.exp "$OVPN_DIR/openvpn-install.sh" "$public_ip" "$proto_choice" "$ovpn_port" "$dns" "$client" \
		> "$OVPN_DIR/openvpn-install.log" 2>&1 || die "OpenVPN installer failed; see $OVPN_DIR/openvpn-install.log"
	[[ -f /etc/openvpn/server/server.conf ]] || die "OpenVPN installer finished but no server config; see $OVPN_DIR/openvpn-install.log"
	say "OpenVPN installed"
	echo "RESULT_OPENVPN=installed"
else
	echo "RESULT_OPENVPN=skipped"
fi

# ---- 5. WireGuard
if [[ -f /etc/wireguard/wg0.conf ]]; then
	[[ -n "$WG_DIR" && -f "$WG_DIR/wireguard-install.sh" ]] || WG_DIR=$(find_script wireguard-install.sh)
	if [[ -z "$WG_DIR" ]]; then
		WG_DIR=/root/vpn-setup; install -d -m 700 "$WG_DIR"
		fetch "$WG_URL" "$WG_DIR/wireguard-install.sh"
	fi
	say "WireGuard already installed (port $(awk -F' = ' '/^ListenPort/{print $2}' /etc/wireguard/wg0.conf)); keeping it. Profiles: $WG_DIR"
	echo "RESULT_WIREGUARD=existing"
elif [[ $want_wg -eq 1 ]]; then
	if [[ -f /etc/openvpn/server/server.conf ]] && grep -qE '^proto udp' /etc/openvpn/server/server.conf \
		&& grep -qx "port $wg_port" /etc/openvpn/server/server.conf; then
		die "OpenVPN already uses UDP port $wg_port; pick another WireGuard port"
	fi
	WG_DIR=/root/vpn-setup; install -d -m 700 "$WG_DIR"
	say "Installing WireGuard (udp $wg_port) with Nyr's wireguard-install"
	fetch "$WG_URL" "$WG_DIR/wireguard-install.sh"
	/usr/local/lib/vpn-sync/nyr-answer.exp "$WG_DIR/wireguard-install.sh" "$public_ip" 1 "$wg_port" "$dns" "$client" \
		> "$WG_DIR/wireguard-install.log" 2>&1 || die "WireGuard installer failed; see $WG_DIR/wireguard-install.log"
	[[ -f /etc/wireguard/wg0.conf ]] || die "WireGuard installer finished but no wg0.conf; see $WG_DIR/wireguard-install.log"
	say "WireGuard installed"
	echo "RESULT_WIREGUARD=installed"
else
	echo "RESULT_WIREGUARD=skipped"
fi

[[ -n "$OVPN_DIR$WG_DIR" ]] || die "neither OpenVPN nor WireGuard is installed"
OVPN_DIR=${OVPN_DIR:-/root/vpn-setup}
WG_DIR=${WG_DIR:-/root/vpn-setup}

# ---- 6. config, permissions, timer
cat > /etc/vpn-sync.conf <<EOF
# written by vpn-sync install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
OVPN_DIR=$OVPN_DIR
WG_DIR=$WG_DIR
DNS_CHOICE=$DNS_CHOICE
EOF
chmod 644 /etc/vpn-sync.conf
for d in "$OVPN_DIR" "$WG_DIR"; do
	chmod 700 "$d"
	find "$d" -maxdepth 1 -type f \( -name '*.ovpn' -o -name '*.conf' -o -name '*.png' -o -name '*.log' \) -exec chmod 600 {} +
done
systemctl daemon-reload
systemctl enable --now vpn-endpoint-sync.timer >/dev/null 2>&1
# traffic totals per day/month for the Traffic view (keeps counting while the app is closed)
systemctl enable --now vnstat >/dev/null 2>&1 || true
/usr/local/sbin/vpn-endpoint-sync
echo "SETUP_OK"
