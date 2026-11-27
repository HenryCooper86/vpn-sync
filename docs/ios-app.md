# VPN Sync for iPhone — design

A manager for the same servers the Mac app manages. It talks to each server over SSH itself
(no Mac needed once it's set up) and runs the same server tools the Mac CLI runs. Connecting
the phone to a VPN stays in the WireGuard / OpenVPN apps and iOS Settings (IKEv2).

## Scope (v1)

- **Servers:** every imported server with its services (OpenVPN, WireGuard, IPsec), how many
  devices are online, a 15-minute speed sparkline and limit attention (paused / near a limit).
- **Server:** Devices · Traffic · Activity, like the Mac.
  - Above the tabs: the server's ports (OpenVPN, WireGuard, IKEv2, SSH) and the Check Profiles
    card: whether the profiles use the server's current IP (Update Profiles runs
    `vpn-endpoint-sync`), and the devices added, removed or given new profiles since the last
    check (from `vpn-export-profiles --hashes`; the fingerprints are kept on the phone).
  - Devices: who's online (live, from `vpn-status --watch`), how and from where (address and
    port), speed, usage today / this month, the limit meter, Paused badge.
  - Device sheet: its connection on each VPN (the server port, its own address and port, its VPN
    address), Pause/Resume Internet, Set/Edit/Remove Usage Limit, profiles (WireGuard QR
    full screen; share or save the `.conf`, `.ovpn`, `.mobileconfig`, `.sswan`, `.p12`),
    Remove Device (confirm).
  - Traffic: speed chart (download above, upload below), today's VPN data, server traffic per
    day (vnstat), data per device this month (server-side counts).
  - Activity: connects/disconnects and limit events while the app is open.
  - Toolbar: Add Device; services menu (start/stop/restart each VPN, reboot, with confirmation;
    Stop/Start Server on Lightsail when the export included the Lightsail key).
- **Settings:** import servers, Face ID lock (on by default), warning level, remove a server.

Not in v1: background notifications (iOS gives no background time for a live SSH stream),
setting up new servers (`server install`), changing ports, adding servers by hand. With the
Lightsail key the phone finds a stopped-and-started server's new IP itself; without it, a check
or a Mac sync updates it.

## Connection

- **SSH:** Apple's swift-nio-ssh + swift-nio + swift-crypto only (no third-party SSH code: the
  keys are root-capable). Ed25519 user keys (OpenSSH format) and Ed25519 host keys, which is
  what both servers use; anything else is reported as unsupported.
- **Host keys are pinned:** the import carries each server's pinned key from
  `~/.config/vpn-sync/known_hosts`; a different key refuses the connection.
- **Order:** through the jump server first when the server has one (a direct-tcpip channel to the
  private IP, with a second SSH session inside it), then the last known IP, then the configured
  host. One connection per server is shared by the live stream and every command.
- **Commands:** exactly the Mac CLI's remote commands, with `sudo -n` when the user isn't root:
  `vpn-status --watch 3` (one stream per server while the app is open), `vpn-usage report |
  limit | pause | resume`, `vpn-service`, `vpn-add-client`, `vpn-remove-client`,
  `vpn-endpoint-sync [--dry-run]`, `vpn-export-profiles --device NAME` (one device's files as an
  uncompressed tar) and `vpn-export-profiles --hashes`.

## Getting servers onto the phone

The Mac app's Settings gets an **iPhone** tab: **Export for iPhone…** writes
`VPN Sync servers.vpnsync` and offers AirDrop. The file is JSON (servers: name, host, user,
port, jump, private IP, last IP, pinned host key, the OpenSSH private key) encrypted with
AES-GCM; the key comes from a passphrase the Mac generates and shows (PBKDF2-SHA256, 600k
rounds, random salt). On the phone, opening the file (AirDrop, Files) asks for the passphrase;
keys go to the Keychain (this device only, when unlocked), the rest to app storage. A newer
import replaces servers with the same name.

## Code layout

- `shared/` — Foundation-only code compiled into both apps: live types (OVPN/WG/IKE
  connections, rates, services, events, traffic points), the usage/limit model and its
  parsing, byte/speed formatting.
- `ios/` — `VPNSyncPhone.xcodeproj` (synchronized folder, Swift packages above) and the app:
  `SSH/` (client, key parsing, jump, exec streams), `Model/` (store, watcher per server,
  import), `Views/`.
- Mac: `app/build.sh` also compiles `shared/`; the export lives in the Mac app.

## Look

Native iOS: NavigationStack, lists of glass cards, SF Symbols, Swift Charts, the system
accent colour, light and dark. Liquid Glass (`glassEffect`) on iOS 26, material fallback on
iOS 17–18.

## Installing

Free Apple ID from Xcode: the app has to be reinstalled every 7 days. Bundle ID
`local.vpnsync.phone` (no paid capabilities: no push, no App Groups, no Network Extension).
