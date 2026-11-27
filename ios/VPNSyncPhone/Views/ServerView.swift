// One server: services (start/stop/restart, reboot), then Devices, Traffic or Activity.
import SwiftUI

struct ServerView: View {
    @EnvironmentObject var store: Store
    let name: String
    @ObservedObject var live: ServerLive

    enum Tab: String, CaseIterable { case devices = "Devices", traffic = "Traffic", activity = "Activity" }
    @State private var tab: Tab = .devices
    @State private var selected: DeviceInfo?
    @State private var adding = false
    @State private var confirm: ServiceAction?
    @State private var busy: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                servicesRow
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t == .activity && activityCount > 0 ? "Activity (\(activityCount))" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .devices: DevicesList(live: live, selected: $selected)
                case .traffic: TrafficSection(live: live)
                case .activity: ActivitySection(live: live)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Backdrop())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Device")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { live.restart() }
                    Divider()
                    Button("Restart All VPNs…", systemImage: "arrow.triangle.2.circlepath") { confirm = ServiceAction(server: name, vpn: "all", action: "restart") }
                    Button("Reboot Server…", systemImage: "power", role: .destructive) { confirm = ServiceAction(server: name, vpn: "reboot", action: "reboot") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Server actions")
            }
        }
        .refreshable { live.restart() }
        .sheet(item: $selected) { d in DeviceSheet(server: name, device: d, live: live) }
        .sheet(isPresented: $adding) { AddDeviceSheet(server: name, live: live) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let a = confirm {
                Button(a.action == "reboot" ? "Reboot" : a.action.capitalized, role: a.action == "start" ? nil : .destructive) { run(a) }
            }
        } message: {
            Text(confirm?.action == "reboot" ? "Every device is disconnected for about a minute." : "Devices on it reconnect on their own.")
        }
        .overlay(alignment: .bottom) { if let busy { ProgressView(busy).padding().card(16, padding: 4).padding() } }
        .onAppear { openRequestedTab() }
    }

    private var activityCount: Int { live.events.count + live.usageEvents.count }

    private var header: some View {
        let s = store.server(name)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s?.address ?? "").font(.system(.body, design: .monospaced))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(live.onlineNames.count)").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("online").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var statusText: String {
        switch live.link {
        case .off: return "Not connected"
        case .connecting: return "Connecting…"
        case .live: return live.lastSnapshot.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Live"
        case .retrying(let why): return "\(why) Retrying…"
        }
    }

    private var servicesRow: some View {
        HStack(spacing: 8) {
            Group {
                ForEach([("openvpn", "OpenVPN"), ("wireguard", "WireGuard"), ("ipsec", "IPsec")], id: \.0) { key, label in
                    if let s = live.services[key], s.state != "missing" {
                        Menu {
                            if s.state == "active" {
                                Button("Restart \(label)…") { confirm = ServiceAction(server: name, vpn: key, action: "restart") }
                                Button("Stop \(label)…", role: .destructive) { confirm = ServiceAction(server: name, vpn: key, action: "stop") }
                            } else {
                                Button("Start \(label)") { run(ServiceAction(server: name, vpn: key, action: "start")) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                StatusDot(color: s.state == "active" ? Palette.online : s.state == "failed" ? .red : .secondary, on: s.state == "active")
                                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                if s.state != "active" {
                                    Text(s.state == "inactive" ? "stopped" : s.state).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .pill(s.state == "failed" ? .red : nil)
                        }
                        .tint(.primary)
                        .accessibilityLabel("\(label), \(s.state == "active" ? "running" : s.state)")
                    }
                }
            }
        }
    }

    private var confirmTitle: String {
        guard let a = confirm else { return "" }
        if a.action == "reboot" { return "Reboot \(name)?" }
        return "\(a.action.capitalized) \(a.vpnLabel) on \(name)?"
    }

    private func run(_ a: ServiceAction) {
        confirm = nil
        busy = a.action == "reboot" ? "Rebooting…" : "\(a.action.capitalized)ing \(a.vpnLabel)…"
        Task {
            defer { busy = nil }
            do {
                if a.action == "reboot" {
                    _ = try await store.tool(name, "/usr/local/sbin/vpn-service reboot", timeout: 30)
                    store.show("\(name) is rebooting. It's usually back within a minute.")
                } else {
                    _ = try await store.tool(name, "/usr/local/sbin/vpn-service \(a.vpn) \(a.action)", timeout: 90)
                    store.show("\(a.vpnLabel): \(a.action == "stop" ? "stopped" : a.action == "start" ? "started" : "restarted").")
                }
            } catch { store.show(error.localizedDescription) }
        }
    }

    /// Test hook (DEBUG): -tab traffic|activity, -device NAME.
    private func openRequestedTab() {
        #if DEBUG
        if let t = UserDefaults.standard.string(forKey: "tab"), let v = Tab(rawValue: t.capitalized) { tab = v }
        if let d = UserDefaults.standard.string(forKey: "device"), selected == nil {
            Task { try? await Task.sleep(nanoseconds: 2_500_000_000); selected = live.allDevices.first { $0.name == d } }
        }
        #endif
    }
}
