// Stopping and starting Lightsail servers (vpn-sync aws state | stop | start). Needs a key that
// may call lightsail:StopInstance and lightsail:StartInstance (Settings → Lightsail). Stopping also
// closes the server's VPN ports in the Lightsail firewall and starting opens them again (SSH stays
// open), which needs GetInstancePortStates, OpenInstancePublicPorts and CloseInstancePublicPorts,
// the same as Change Ports. A server without a static IP comes back with a new address: VPN Sync
// looks it up and resyncs.
import SwiftUI

struct InstanceState: Equatable {
    var state: String          // running, stopped, stopping, pending, unknown
    var ip: String?
    var staticIP: Bool
    var isRunning: Bool { state == "running" }
    var isDown: Bool { state == "stopped" || state == "stopping" }
    var label: String {
        switch state {
        case "running": return String(localized: "running", comment: "server state, lowercase, used in 'Tokyo is running'")
        case "stopped": return String(localized: "stopped", comment: "server state, lowercase, used in 'Tokyo is stopped'")
        case "stopping": return String(localized: "stopping…", comment: "server state, lowercase")
        case "pending": return String(localized: "starting…", comment: "server state, lowercase")
        default: return state
        }
    }
}

extension Model {
    func isLightsail(_ s: String) -> Bool { !(configValue("LIGHTSAIL_REGION", server: s) ?? "").isEmpty }

    /// Asks Lightsail whether the instance is running (quietly; nil without a key or on error).
    @discardableResult
    func refreshInstanceState(_ s: String) async -> InstanceState? {
        guard isLightsail(s) else { return nil }
        let (code, out) = await runCLI(["aws", "state", s], quiet: true)
        guard code == 0 else { return nil }
        let kv = parseKV(out)
        guard let st = kv["STATE"] else { return nil }
        let state = InstanceState(state: st, ip: kv["IP"], staticIP: kv["STATIC_IP"] == "yes")
        instanceStates[s] = state
        return state
    }

    /// What `aws stop` / `aws start` did in the Lightsail firewall, as notices.
    private func portNotices(_ out: String, start: Bool) -> [String] {
        let kv = parseKV(out)
        var n: [String] = []
        if let c = kv["PORTS_CLOSED"] { n.append(String(localized: "Its VPN ports are closed in the Lightsail firewall until it starts again: \(c). SSH stays open.")) }
        if let o = kv["PORTS_OPENED"] { n.append(String(localized: "Its VPN ports are open again in the Lightsail firewall: \(o).")) }
        if let f = kv["PORTS_FAILED"] {
            n.append(start ? String(localized: "Couldn't open \(f) in the Lightsail firewall. Open them on the instance's Networking tab, or check the key's policy in Settings → Lightsail.")
                           : String(localized: "Couldn't close \(f) in the Lightsail firewall. Check the key's policy in Settings → Lightsail."))
        }
        return n
    }

    /// Stops or starts a Lightsail server. Starting waits until it's running and reachable again,
    /// then resyncs (a new IP is found and the profiles updated) and reconnects live monitoring.
    func powerServer(_ s: String, start: Bool) async {
        if start {
            instanceStates[s] = InstanceState(state: "pending", ip: nil, staticIP: instanceStates[s]?.staticIP ?? false)
            let (code, out) = await cli(["aws", "start", s, "--wait"], label: String(localized: "Starting \(s)…"))
            guard code == 0 else {
                status = .failed(String(localized: "Start failed: \(lastLines(out, 2).replacingOccurrences(of: "vpn-sync: ", with: ""))"))
                await refreshInstanceState(s)
                return
            }
            await refreshInstanceState(s)
            let fw = portNotices(out, start: true)
            notices = [String(localized: "\(s) is running again. Waiting for it to finish booting…")] + fw
            // the VPNs need a minute after the instance reports running
            for _ in 0..<18 {
                let (c, _) = await runCLI(["--check", s], quiet: true)
                if c == 0 { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
            unreachableNotified.remove(s)
            await recover(s)
            notices = [instanceStates[s]?.staticIP == false
                ? String(localized: "\(s) is back. If its IP changed, the profiles on the Desktop are updated; phones and TVs need them again.")
                : String(localized: "\(s) is back.")] + fw
        } else {
            let (code, out) = await cli(["aws", "stop", s], label: String(localized: "Stopping \(s)…"))
            guard code == 0 else {
                status = .failed(String(localized: "Stop failed: \(lastLines(out, 2).replacingOccurrences(of: "vpn-sync: ", with: ""))"))
                return
            }
            instanceStates[s] = InstanceState(state: "stopping", ip: nil, staticIP: instanceStates[s]?.staticIP ?? false)
            notices = [String(localized: "\(s) is stopping. Every device is disconnected until you start it again.")] + portNotices(out, start: false)
            status = .upToDate
            // follow it until Lightsail says stopped
            Task { @MainActor in
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if let st = await self.refreshInstanceState(s), st.state == "stopped" { break }
                }
            }
        }
    }
}

/// "Tokyo is stopped" with a Start button, above the device list.
struct StoppedBanner: View {
    @EnvironmentObject var m: Model
    let server: String
    var body: some View {
        if let st = m.instanceStates[server], !st.isRunning {
            HStack(spacing: 12) {
                LucideIcon(st.state == "pending" ? "refresh-cw" : "power", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(server) is \(st.label)").font(.callout.weight(.semibold))
                    Text(st.state == "pending" ? "It's booting; live monitoring reconnects when it's ready."
                         : "The Lightsail instance isn't running, so no device can connect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if st.state == "stopped" {
                    Button("Start Server") { Task { await m.powerServer(server, start: true) } }
                        .glassButton(prominent: true)
                        .disabled(m.busy)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            .glassPanel(18, tint: .orange)
        }
    }
}
