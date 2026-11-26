# VPN Sync

A macOS app and command-line tool for running your own OpenVPN + WireGuard servers
(using [Nyr's road-warrior installers](https://github.com/Nyr)) on Lightsail or any VPS.

- **Set up servers:** add a server with its IP and SSH key (`.pem`), verify its host key,
  and install OpenVPN and/or WireGuard with your choice of protocol, ports and DNS.
  Servers that already run a Nyr install are adopted as they are.
- **Manage devices:** add, remove, batch add (`m1`…`m15`) and batch remove devices on both
  VPNs at once. WireGuard profiles come with QR codes for phones and TVs.
- **Survive IP changes:** each server rewrites its own profiles when its public IP
  changes (at boot and every 15 minutes). The Mac pulls fresh profiles to
  `~/Desktop/<server>-<ip>/` and fixes OpenVPN Connect's saved profile. With a read-only
  Lightsail key (Settings → Lightsail), VPN Sync finds a server's new IP after a stop/start
  on its own, resyncs, and sends a notification.
- **Watch it live:** see which devices are connected, from where, since when, and how
  fast, with a log of connects and disconnects, and a macOS notification whenever a
  device connects or disconnects on any server.
- **Traffic:** a Traffic tab with today's VPN data (donut), a mirrored speed chart
  (download above the line, upload below; 5 min / 15 min / 1 h; MB/s or Mbit/s), peak speed,
  connections, most devices online at once, the server's own totals from `vnstat`, and
  devices and protocols ranked by data. Star a device to pin it to the top.
- **Device types:** what each OpenVPN client reports (iPhone, Android, Mac, Windows, Linux,
  and the app version) is read from the server log; WireGuard devices are guessed from their
  name. Set any device's type yourself from its ⋯ menu.
- **Device locations:** a country flag next to each device's address. The lookup is offline,
  using ip-location-db's `user-country` table (public domain, PDDL, updated daily);
  `vpn-sync geo update` fetches the latest one, checks its SHA-256 and format, and saves it to
  `~/.config/vpn-sync/geo/`. No address is sent anywhere.
- **Control services:** start, stop or restart OpenVPN and WireGuard, or reboot the server.
- **Menu bar:** a shield with the number of devices online across all servers; click it to
  see who is connected where, or rename (pencil) or remove (trash) a server. Closing the
  window keeps VPN Sync running there (quit from
  the menu bar panel or with ⌘Q).
- **Reach locked-down servers:** connect through another server over a private network
  (for example two Lightsail instances in one region) so SSH can stay closed to the internet.

## Install (macOS)

Needs Xcode or the Command Line Tools (to build the app).

```bash
./install-mac.sh
```

This installs `~/.local/bin/vpn-sync` (make sure `~/.local/bin` is on your `PATH`), the
server bundle in `~/.local/share/vpn-sync/server`, and `~/Applications/VPN Sync.app`.

## Look and feel

Liquid Glass panels and buttons on see-through windows that blur what's behind them, with
material fallbacks on macOS 14–15. Icons are [Lucide](https://lucide.dev) (ISC licence),
bundled as SVGs in `app/lucide/`. Settings → Appearance: Automatic (follows macOS), Light or
Dark; buttons use your macOS accent colour. The header's signal orb shows how many devices are
online and ripples when one connects (not with Reduce Motion). The app icon, a glass shield
with a tunnel narrowing to a lit keyhole, is drawn by `app/make-icon.swift`.

## Using the app

1. **Add Server…**: name, IP, SSH user, private key (`.pem`). Optionally "connect through
   another server" with its private IP. Check the fingerprint, then **Trust and Add**.
2. **Set Up**: VPN Sync shows what's installed. For a fresh server pick OpenVPN TCP/UDP and
   port, WireGuard port, DNS and the first device name, then **Install** (a few minutes).
   Open the same ports in the provider's firewall (Lightsail: instance → Networking).
3. Use **Add Device / Batch Add… / Batch Remove…** and the row menu to manage devices,
   **QR** to show a WireGuard code, **Sync Now** after an IP change, and **Live** for
   monitoring (the bell turns notifications on or off). Use the **OpenVPN / WireGuard**
   menus to start, stop or restart a VPN and **Server → Reboot Server…** to reboot. Switch
   servers from the server name menu; edit IP, key or user in **Servers**.

## Command line

```
vpn-sync [server...]                       sync profiles to the Desktop
vpn-sync --check [server]                  show what would change
vpn-sync --ip A.B.C.D <server>             use this address
vpn-sync --add a,b,c <server>              create devices
vpn-sync --remove a,b <server>             revoke/remove devices
vpn-sync status <server>                   who is connected now
vpn-sync watch <server> [--interval N]     stream connection snapshots
vpn-sync service <server> <openvpn|wireguard|all> <start|stop|restart|status>
vpn-sync reboot <server>
vpn-sync server list | add | edit | rename | remove | hostkey | probe | install
```

Run `vpn-sync --help` for all options.

## How it works

| Where | What |
|---|---|
| `vpn-sync` | Mac CLI. Finds each server (`--ip`, AWS CLI, last IP, configured host, jump server, VPN tunnel addresses), always over SSH with a pinned host key. |
| `app/` | SwiftUI front end that runs `vpn-sync`. Logs every command to `~/.config/vpn-sync/history.log`. |
| `server/install.sh` | Uploaded and run by `vpn-sync server install`. Installs packages and tools, installs the VPNs if missing, writes `/etc/vpn-sync.conf`. |
| `server/bin/vpn-endpoint-sync` | Rewrites profiles and templates for the current public IP and refreshes QR codes (systemd timer). |
| `server/bin/vpn-add-client`, `vpn-remove-client` | Add/remove devices on both VPNs by driving the Nyr menus with `expect`. All names are validated first. Removed files are kept in `/root/vpn-sync-backups/`. |
| `server/bin/vpn-export-profiles` | Streams all client profiles as a tarball. |
| `server/bin/vpn-status` | Connected devices (OpenVPN status file and log, `wg show` handshakes) and service state. |
| `server/bin/vpn-service` | Start/stop/restart the VPN services, or reboot. Stopped services start again at boot. |

Local state lives in `~/.config/vpn-sync/`: one `<server>.conf` per server (see
`examples/server.conf.example`), copies of the SSH keys in `keys/`, pinned host keys in
`known_hosts`, and the last seen IP per server. None of it belongs in this repository.

## Notes

- macOS asks once whether VPN Sync may access the Desktop folder (profiles live there) and
  send notifications. A locally built app is signed ad hoc, so every rebuild counts as a new
  app and macOS asks again.

- Revoking an OpenVPN certificate can't be undone; the app always asks first.
- OpenVPN's status file refreshes every 60 s, so OpenVPN transfer speeds update once a
  minute; connects and disconnects show up within seconds from the log.
- A WireGuard device counts as connected while its last handshake is under 3 minutes old.
- Phones and TVs can't be updated remotely. After an IP change, re-import or rescan their
  profiles from the Desktop folder. A static IP avoids this entirely.
