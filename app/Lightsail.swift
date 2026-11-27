// Stopping and starting Lightsail servers (vpn-sync aws state | stop | start). Needs a key that
// may call lightsail:StopInstance and lightsail:StartInstance (Settings → Lightsail; Change Ports
// also needs GetInstancePortStates, OpenInstancePublicPorts and CloseInstancePublicPorts). A server
// without a static IP comes back with a new address: VPN Sync looks it up and resyncs.
import SwiftUI

struct InstanceState: Equatable {
    var state: String          // running, stopped, stopping, pending, unknown
    var ip: String?
    var staticIP: Bool
    var isRunning: Bool { state == "running" }
    var isDown: Bool { state == "stopped" || state == "stopping" }
    var label: String {
        switch state {
        case "running": return "running"
        case "stopped": return "stopped"
        case "stopping": return "stopping…"
        case "pending": return "starting…"
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

    /// Stops or starts a Lightsail server. Starting waits until it's running and reachable again,
    /// then resyncs (a new IP is found and the profiles updated) and reconnects live monitoring.
    func powerServer(_ s: String, start: Bool) async {
        if start {
            instanceStates[s] = InstanceState(state: "pending", ip: nil, staticIP: instanceStates[s]?.staticIP ?? false)
            let (code, out) = await cli(["aws", "start", s, "--wait"], label: "Starting \(s)…")
            guard code == 0 else {
                status = .failed("Start failed: \(lastLines(out, 2).replacingOccurrences(of: "vpn-sync: ", with: ""))")
                await refreshInstanceState(s)
                return
            }
            await refreshInstanceState(s)
            notices = ["\(s) is running again. Waiting for it to finish booting…"]
            // the VPNs need a minute after the instance reports running
            for _ in 0..<18 {
                let (c, _) = await runCLI(["--check", s], quiet: true)
                if c == 0 { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
            unreachableNotified.remove(s)
            await recover(s)
            notices = ["\(s) is back." + (instanceStates[s]?.staticIP == false ? " If its IP changed, the profiles on the Desktop are updated; phones and TVs need them again." : "")]
        } else {
            let (code, out) = await cli(["aws", "stop", s], label: "Stopping \(s)…")
            guard code == 0 else {
                status = .failed("Stop failed: \(lastLines(out, 2).replacingOccurrences(of: "vpn-sync: ", with: ""))")
                return
            }
            instanceStates[s] = InstanceState(state: "stopping", ip: nil, staticIP: instanceStates[s]?.staticIP ?? false)
            notices = ["\(s) is stopping. Every device is disconnected until you start it again."]
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
