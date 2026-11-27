# VPN Sync

A macOS app and command-line tool for running your own OpenVPN + WireGuard servers
(using [Nyr's road-warrior installers](https://github.com/Nyr)) on Lightsail or any VPS,
optionally with IPsec/IKEv2 (using [hwdsl2's setup-ipsec-vpn](https://github.com/hwdsl2/setup-ipsec-vpn)).

- **Set up servers:** add a server with its IP and SSH key (`.pem`), verify its host key,
  and install OpenVPN and/or WireGuard with your choice of protocol, ports and DNS.
  Servers that already run a Nyr install are adopted as they are.
- **Manage devices:** add, remove, batch add (`m1`…`m15`) and batch remove devices on every
  VPN at once. WireGuard profiles come with QR codes for phones and TVs.
- **IPsec/IKEv2 (optional):** the VPN built into macOS, iOS, Windows and Android, no app
  needed. Installed in IKEv2-only mode (the older IPsec/L2TP and Cisco IPsec modes, which use
  a shared key and password, are off). Every device gets `IKEv2/<name>.mobileconfig` (macOS,
  iOS), `.sswan` (Android, strongSwan) and `.p12` (Windows); removing a device revokes its
  certificate. IKEv2 devices show up live, are counted for usage limits and can be paused like
  the others. If the server's IP changes, it gets a new server certificate and the IKEv2
  profiles are made again: install them again on each device. Needs UDP 500 and 4500 open.
- **Survive IP changes:** each server rewrites its own profiles when its public IP
  changes (at boot and every 15 minutes). The Mac pulls fresh profiles to
  `~/Desktop/<server>-<ip>/` and fixes OpenVPN Connect's saved profile. With a read-only
  Lightsail key (Settings → Lightsail), VPN Sync finds a server's new IP after a stop/start
  on its own, resyncs, and sends a notification.
- **Watch it live:** see which devices are connected, from where, since when, and how
  fast, with a log of connects and disconnects, and a macOS notification whenever a
  device connects or disconnects on any server.
- **Traffic:** a Traffic tab with today's VPN data (donut), a mirrored speed chart
  (download above the line, upload below; 5 min / 15 min / 1 h; MB/s or Mbit/s), devices
  online over time, the server's traffic per day for 30 days (`vnstat`), peak speed,
  connections, most devices online at once, and devices (with download/upload sparklines) and protocols
  ranked by data. Star a device to pin it to the top.
- **Device types:** what each OpenVPN client reports (iPhone, Android, Mac, Windows, Linux,
  and the app version) is read from the server log; WireGuard devices are guessed from their
  name. Set any device's type yourself from its ⋯ menu.
- **Device locations:** a country flag next to each device's address. The lookup is offline,
  using ip-location-db's `user-country` table (public domain, PDDL, updated daily);
  `vpn-sync geo update` fetches the latest one, checks its SHA-256 and format, and saves it to
  `~/.config/vpn-sync/geo/`. The app refreshes it automatically every month. No address is
  sent anywhere.
- **Control services:** start, stop or restart OpenVPN, WireGuard and IPsec, or reboot the server.
- **Usage limits:** each server counts every device's data per day (every minute, so it keeps
  counting while the app is closed). Set a daily and/or monthly limit per device that either
  notifies you (at 80% and 100%; the warning level can be changed) or also pauses the device. **Pause Internet** blocks a
  device's traffic on the server with a firewall rule: it stays connected, nothing is revoked,
  and **Resume Internet** undoes it. A limit pause lifts at midnight (daily) or on the 1st
  (monthly); days follow the Mac's time zone.
  The Devices tab shows each device's usage and limit, says why a paused device is paused
  with a **Resume** button, and has a summary above the list that can filter it to limited
  and paused devices. The menu bar panel and the Traffic tab list limited and paused devices
  with the same actions; the Traffic tab also shows every device's data this month.
  **Settings → Limits** turns limit notifications on or off (separately from connect
  banners) and the menu bar mark, sets the warning level (50–90% or off), and lists every
  limit and pause on
  every server, with **Add a Limit** for each. The Activity tab logs
  limit events (80% used, limit reached, paused, resumed, limit set or removed) alongside
  connects and disconnects while VPN Sync is running.
- **Menu bar:** a shield with the number of devices online across all servers (plus a pause
  mark with the number of paused devices, or a gauge when one nears its limit); click it to
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
   Tick **Also install IPsec/IKEv2** to add IKEv2 (also on servers that already have
   OpenVPN/WireGuard; existing devices get IKEv2 profiles).
   Open the same ports in the provider's firewall (Lightsail: instance → Networking); IKEv2
   needs UDP 500 and 4500.
3. Use **Add Device / Batch Add… / Batch Remove…** and the row menu to manage devices,
   **QR** to show a WireGuard code, **Sync Now** after an IP change, and **Live** for
   monitoring (the bell turns notifications on or off). Use the **OpenVPN / WireGuard**
   menus to start, stop or restart a VPN and **Server → Reboot Server…** to reboot. Switch
   servers from the server name menu; edit IP, key or user in **Servers**. A device's
   **⋯** menu has **Pause Internet** and **Set Usage Limit…**.

## iPhone app

`ios/` holds a companion app for the same servers: who's online (live), speed, data per device
and per day, usage limits, pause/resume, adding and removing devices, service start/stop and
reboot, and each device's profiles (WireGuard QR code, `.conf`, `.ovpn`, IKEv2 `.mobileconfig`,
`.sswan`, `.p12`) to share. It connects to the servers over SSH itself (Apple's swift-nio-ssh;
Ed25519 keys, pinned host keys, through the jump server when needed), so the Mac doesn't have
to be on.

1. On the Mac: **Settings → iPhone → Export for iPhone…** writes an encrypted
   `VPN Sync servers.vpnsync` (AES-GCM, key from a passphrase shown once) and offers AirDrop.
2. Open the file on the iPhone with VPN Sync and type the passphrase. Keys go to the iPhone's
   Keychain (this device only); Face ID locks the app.
3. Build: open `ios/VPNSyncPhone.xcodeproj` in Xcode, put your team in `ios/Local.xcconfig`
   (`DEVELOPMENT_TEAM = …`, git-ignored) and run it on your iPhone. With a free Apple ID it has
   to be reinstalled every 7 days. Design notes: `docs/ios-app.md`.

## Command line

```
vpn-sync [server...]                       sync profiles to the Desktop
vpn-sync --check [server]                  show what would change
vpn-sync --ip A.B.C.D <server>             use this address
vpn-sync --add a,b,c <server>              create devices
vpn-sync --remove a,b <server>             revoke/remove devices
vpn-sync status <server>                   who is connected now
vpn-sync watch <server> [--interval N]     stream connection snapshots
vpn-sync service <server> <openvpn|wireguard|ipsec|all> <start|stop|restart|status>
vpn-sync reboot <server>
vpn-sync usage [server...]                 data per device today and this month, limit, % used
vpn-sync limits [server...]                only devices with a limit or a pause
vpn-sync limit <server> <device>           one device's limit and usage
vpn-sync limit <server> <device> --daily 2GB --monthly 50GB --action alert|pause
vpn-sync limit <server> <device> --clear
vpn-sync pause | resume <server> <device>  block or unblock a device's traffic
vpn-sync server list | add | edit | rename | remove | hostkey | probe | install
vpn-sync server install <server> --ipsec   also install IPsec/IKEv2 (kept once installed)
```

Run `vpn-sync --help` for all options.

## How it works

| Where | What |
|---|---|
| `vpn-sync` | Mac CLI. Finds each server (`--ip`, AWS CLI, last IP, configured host, jump server, VPN tunnel addresses), always over SSH with a pinned host key. |
| `app/` | SwiftUI front end that runs `vpn-sync`. Logs every command to `~/.config/vpn-sync/history.log`. |
| `server/install.sh` | Uploaded and run by `vpn-sync server install`. Installs packages and tools, installs the VPNs if missing, writes `/etc/vpn-sync.conf`. With `--ipsec` it runs hwdsl2's `vpnsetup.sh` (Libreswan, IKEv2), switches to IKEv2-only mode (`ikev1-policy=drop`, `xl2tpd` off) and creates an IKEv2 client per device; client files live in `/root/vpn-setup/ikev2/`. |
| `server/bin/vpn-endpoint-sync` | Rewrites profiles and templates for the current public IP and refreshes QR codes (systemd timer). For IKEv2 it issues a server certificate for the new IP, updates `ikev2.conf`, restarts IPsec and exports every client again. |
| `server/bin/vpn-add-client`, `vpn-remove-client` | Add/remove devices on every VPN by driving the Nyr menus with `expect` and hwdsl2's `ikev2.sh` (`--addclient`; `--revokeclient` then `--deleteclient`). All names are validated first. Removed files are kept in `/root/vpn-sync-backups/`. |
| `server/bin/vpn-export-profiles` | Streams all client profiles as a tarball. |
| `server/bin/vpn-status` | Connected devices (OpenVPN status file and log, `wg show` handshakes, `ipsec trafficstatus`) and service state. |
| `server/bin/vpn-usage` | Per-device data per day in `/var/lib/vpn-sync/usage/` (systemd timer, every minute), limits, and pausing via a `VPNSYNC-BLOCK` chain first in `FORWARD` (IPv4 and IPv6). On the server, `sudo vpn-usage show` prints a table, and `sudo vpn-usage log` lists pauses, resumes and limit changes (also in `journalctl -t vpn-usage`). |
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
