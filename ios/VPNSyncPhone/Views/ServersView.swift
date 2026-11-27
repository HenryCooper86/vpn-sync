// Home: every server as a card (services, who's online, speed, limits), then the server.
import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @State private var settings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    ForEach(store.servers) { s in
                        if let live = store.live[s.name] {
                            NavigationLink(value: s.name) { ServerCard(server: s, live: live) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Backdrop())
            .navigationTitle("VPN Sync")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: String.self) { name in
                if let live = store.live[name] { ServerView(name: name, live: live) }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            .refreshable { for l in store.live.values { l.restart() } }
            .onAppear { openRequestedScreen() }
        }
    }

    private func devicesPhrase(_ n: Int) -> String {
        n == 1 ? String(localized: "1 device") : String(localized: "\(n) devices")
    }
    private func serversPhrase(_ n: Int) -> String {
        n == 1 ? String(localized: "1 server") : String(localized: "\(n) servers")
    }

    private var summary: some View {
        let n = store.onlineEverywhere, a = store.limitAttention
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "\(devicesPhrase(n)) online on \(serversPhrase(store.servers.count))"))
                .font(.subheadline).foregroundStyle(.secondary)
            if a.paused + a.near > 0 {
                Label([a.paused > 0 ? String(localized: "\(a.paused) paused") : nil, a.near > 0 ? String(localized: "\(a.near) at \(store.warnAt)% or more") : nil]
                        .compactMap { $0 }.joined(separator: clauseSep), systemImage: a.paused > 0 ? "pause.circle.fill" : "gauge.with.dots.needle.67percent")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Test hook (DEBUG): -screen ServerName opens that server at launch, -screen settings opens
    /// Settings, for screenshots.
    private func openRequestedScreen() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "screen") == "settings" { settings = true }
        if let s = UserDefaults.standard.string(forKey: "screen"), store.server(s) != nil, path.isEmpty { path.append(s) }
        #endif
    }
}

/// A soft background behind the glass.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.10, green: 0.07, blue: 0.20)]
                       : [Color(red: 0.90, green: 0.94, blue: 1.0), Color(red: 0.96, green: 0.93, blue: 1.0)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct ServerCard: View {
    @EnvironmentObject var store: Store
    let server: ServerConfig
    @ObservedObject var live: ServerLive

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.title3.weight(.semibold))
                    Text(linkText).font(.caption).foregroundStyle(linkColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(live.onlineNames.count)").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("online", comment: "Under a number of devices that are connected right now").font(.caption).foregroundStyle(.secondary)
                }
            }
            ServicesStrip(live: live)
            if live.history.count > 2 {
                if live.history.contains(where: { $0.down > 0 || $0.up > 0 }) { Sparkline(points: live.history) }
                else { Text("No traffic in the last 15 minutes").font(.caption).foregroundStyle(.tertiary) }
            }
            let names = live.onlineNames.sorted()
            if !names.isEmpty {
                Text(names.prefix(4).joined(separator: listSep) + (names.count > 4 ? String(localized: " and \(names.count - 4) more") : ""))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            let a = live.limitAttention
            if a.paused + a.near > 0 {
                Text([a.paused > 0 ? String(localized: "\(a.paused) paused") : nil, a.near > 0 ? String(localized: "\(a.near) near a limit") : nil].compactMap { $0 }.joined(separator: clauseSep))
                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
        }
        .card()
        .contentShape(Rectangle())
    }

    private var linkText: String {
        if let st = store.instances[server.name], !st.isRunning { return String(localized: "Server \(st.label)") }
        switch live.link {
        case .off: return server.address
        case .connecting: return String(localized: "Connecting to \(server.address)…")
        case .live: return String(localized: "Live, \(server.address)")
        case .retrying(let why): return why
        }
    }
    private var linkColor: Color {
        switch live.link { case .live: return .secondary; case .retrying: return .orange; default: return .secondary }
    }
}

/// OpenVPN · WireGuard · IPsec dots.
struct ServicesStrip: View {
    @ObservedObject var live: ServerLive
    var body: some View {
        HStack(spacing: 12) {
            ForEach([("openvpn", "OpenVPN"), ("wireguard", "WireGuard"), ("ipsec", "IPsec")], id: \.0) { key, label in
                if let s = live.services[key], s.state != "missing" {
                    HStack(spacing: 5) {
                        StatusDot(color: s.state == "active" ? Palette.online : s.state == "failed" ? .red : .secondary,
                                  on: s.state == "active", size: 7)
                        Text(label).font(.caption.weight(.medium))
                    }
                }
            }
        }
    }
}
