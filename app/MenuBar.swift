// Menu bar item: a shield with the number of devices online across all servers, and a
// panel listing who is connected on each server.
import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var m: Model
    var body: some View {
        let n = m.onlineEverywhere
        HStack(spacing: 3) {
            Lucide.image(icon, size: 16)
            if m.monitoring { Text("\(n)").monospacedDigit() }
        }
        .help("VPN Sync: \(n) device\(n == 1 ? "" : "s") online")
        .onAppear { debugNote("menubar label appeared icon=\(icon) count=\(n)") }
        .onChange(of: n) { debugNote("menubar count=\(n) icon=\(icon)") }
    }

    /// Test hook (VPNSYNC_DEBUG_DIR): records what the menu bar item shows.
    private func debugNote(_ s: String) {
        guard let dir = ProcessInfo.processInfo.environment["VPNSYNC_DEBUG_DIR"] else { return }
        let url = URL(fileURLWithPath: dir + "/menubar.txt")
        let line = Data("\(Int(Date().timeIntervalSince1970)) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
    private var icon: String {
        if !m.monitoring { return "shield-off" }
        let anyLive = m.watchers.values.contains { $0.link == .live }
        if !anyLive { return "shield" }
        return m.onlineEverywhere > 0 ? "shield-check" : "shield"
    }
}

/// Brings the main window forward, opening it if it was closed.
@MainActor
func showMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
        w.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
}

struct MenuBarPanel: View {
    @ObservedObject var m: Model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme
    /// Server waiting for removal confirmation (inline: alerts tend to close menu bar panels).
    @State private var confirmRemove: String?
    @State private var removeError: (server: String, message: String)?
    @State private var removing = false
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if m.servers.isEmpty {
                Text("No servers yet. Open VPN Sync to add one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel(18)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(m.servers, id: \.self) { s in serverCard(s) }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { showMainWindow(openWindow) } label: { Label("Open VPN Sync", lucide: "app-window") }
                    .glassButton(prominent: true)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.glassButton()
            }
        }
        .padding(16)
        .frame(width: 410)
    }

    private var header: some View {
        HStack(spacing: 12) {
            SignalOrb(count: m.monitoring ? m.onlineEverywhere : nil,
                      live: m.watchers.values.contains { $0.link == .live }, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text("VPN Sync").font(.system(size: 18, weight: .bold, design: .rounded))
                Text(summary).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            LiveToggle().environmentObject(m)
        }
    }

    private var summary: String {
        let n = m.servers.count
        let servers = "\(n) server\(n == 1 ? "" : "s")"
        guard m.monitoring else { return "Live monitoring is off" }
        return "\(m.onlineEverywhere) online on \(servers)"
    }

    @ViewBuilder private func serverCard(_ s: String) -> some View {
        let w = m.watchers[s]
        let online = w?.onlineDevices ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(linkColor(w?.link ?? .off)).frame(width: 8, height: 8)
                    .shadow(color: w?.link == .live ? theme.online.opacity(0.8) : .clear, radius: 3)
                Button {
                    m.selectServer(s)
                    showMainWindow(openWindow)
                } label: { Text(s).font(.system(size: 15, weight: .semibold, design: .rounded)) }
                    .buttonStyle(.plain)
                    .help("Open \(s) in VPN Sync")
                if m.monitoring {
                    Text(linkText(w, count: online.count))
                        .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    removeError = nil; confirmRemove = nil
                    if renaming == s { renaming = nil } else { renaming = s; newName = s; nameFocused = true }
                } label: { LucideIcon("pencil") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .disabled(removing)
                    .help("Rename \(s)")
                    .accessibilityLabel("Rename \(s)")
                Button {
                    removeError = nil; renaming = nil
                    confirmRemove = (confirmRemove == s ? nil : s)
                } label: { LucideIcon("trash-2") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .disabled(removing)
                    .help("Remove \(s) from VPN Sync")
                    .accessibilityLabel("Remove \(s)")
            }
            if renaming == s {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("New name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onSubmit { rename(s) }
                            .disabled(removing)
                        Button("Cancel") { renaming = nil }.glassButton().disabled(removing)
                        Button("Rename") { rename(s) }
                            .glassButton(prominent: true)
                            .disabled(removing || renameProblem(s) != nil || newName == s)
                    }
                    if let p = renameProblem(s), !newName.isEmpty {
                        Text(p).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Its Desktop folder is renamed too. Devices and the server itself aren't affected.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .glassPanel(14)
            }
            if confirmRemove == s {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remove \(s) from VPN Sync?").font(.system(.callout, design: .rounded).weight(.semibold))
                    Text("Deletes its settings, the copy of its key and its pinned host key on this Mac. The server keeps running, its devices keep working, and its Desktop folder is kept.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if removing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Cancel") { confirmRemove = nil }.glassButton().disabled(removing)
                        Button("Remove", role: .destructive) { remove(s) }
                            .tint(.red).glassButton(prominent: true).disabled(removing)
                    }
                }
                .padding(10)
                .glassPanel(14, tint: .red)
            }
            if let e = removeError, e.server == s {
                Text(e.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if m.monitoring && w?.link == .live {
                if online.isEmpty {
                    Text("No devices online").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(online, id: \.name) { d in
                            HStack(spacing: 10) {
                                DeviceAvatar(name: d.name, online: true, size: 26, kind: m.deviceKind(d.name))
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(d.name).font(.system(size: 13, weight: .semibold, design: .rounded))
                                        if let p = m.usageByServer[s]?.paused[d.name] { PausedBadge(info: p) }
                                    }
                                    Text(d.via).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Sparkline(history: w?.deviceHistory[d.name] ?? [], name: d.name, width: 56, height: 20)
                                if let r = d.rate {
                                    VStack(alignment: .trailing, spacing: 0) {
                                        Label(formatRate(r.down), lucide: "arrow-down", size: 10)
                                        Label(formatRate(r.up), lucide: "arrow-up", size: 10).foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .labelStyle(TightLabel())
                                }
                            }
                        }
                    }
                }
            } else if m.monitoring && (w?.link == .retrying) {
                Text("Can't reach it right now. Retrying.").font(.callout).foregroundStyle(.secondary)
            }
            PanelLimits(m: m, server: s) { showMainWindow(openWindow) }
        }
        .padding(12)
        .glassPanel(18)
    }

    private func renameProblem(_ s: String) -> String? {
        if newName.isEmpty { return "Enter a name." }
        if !isValidServerName(newName) { return "Use letters, numbers, - and _ (no spaces), up to 40." }
        if newName != s && m.servers.contains(newName) { return "“\(newName)” already exists." }
        return nil
    }

    private func rename(_ s: String) {
        guard renameProblem(s) == nil, newName != s, !removing else { return }
        removing = true
        let to = newName
        Task {
            let (code, out) = await m.cli(["server", "rename", s, to], label: "Renaming \(s)…")
            removing = false
            renaming = nil
            if code == 0 {
                m.reloadServers(select: m.server == s ? to : nil)
            } else {
                let msg = out.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "vpn-sync: ", with: "") }
                removeError = (s, "Not renamed: \(msg ?? "unknown error").")
            }
        }
    }

    private func remove(_ s: String) {
        removing = true
        Task {
            let (code, out) = await m.cli(["server", "remove", s], label: "Removing \(s)…")
            removing = false
            if code == 0 {
                confirmRemove = nil
                let wasSelected = m.server == s
                m.reloadServers()
                if wasSelected && !m.server.isEmpty { await m.check() }
            } else {
                confirmRemove = nil
                // e.g. "edge-2 connects through edge-1; change that first"
                let msg = out.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "vpn-sync: ", with: "") }
                removeError = (s, "Not removed: \(msg ?? "unknown error").")
            }
        }
    }

    private func linkColor(_ l: LiveLink) -> Color {
        switch l {
        case .live: return theme.online
        case .connecting, .retrying: return .orange
        case .off: return .secondary
        }
    }
    private func linkText(_ w: ServerWatcher?, count: Int) -> String {
        switch w?.link ?? .off {
        case .live:
            let paused = w.flatMap { m.usageByServer[$0.server]?.paused.count } ?? 0
            return "\(count) online" + (paused > 0 ? ", \(paused) paused" : "")
        case .connecting: return "connecting…"
        case .retrying: return "unreachable"
        case .off: return "not monitored"
        }
    }
}

/// Test hook: with VPNSYNC_PANEL_PREVIEW set, also show the menu bar panel in an ordinary
/// window so it can be screenshotted without clicking the menu bar.
@MainActor
func openPanelPreviewIfRequested(_ m: Model) {
    guard ProcessInfo.processInfo.environment["VPNSYNC_PANEL_PREVIEW"] != nil else { return }
    let host = NSHostingView(rootView: Themed { MenuBarPanel(m: m).environmentObject(m) })
    let w = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 410, height: 520),
                     styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = "Menu bar panel preview"
    w.titlebarAppearsTransparent = true
    w.contentView = host
    w.isReleasedWhenClosed = false
    w.makeKeyAndOrderFront(nil)
    panelPreviewWindow = w
}
@MainActor var panelPreviewWindow: NSWindow?

/// Test hook: VPNSYNC_PREVIEW=settings|servers|addserver|edit|add|batch|qr|limit opens that window or
/// sheet a few seconds after launch, for screenshots without clicking.
@MainActor
func openSheetPreviewIfRequested(_ m: Model) {
    guard let what = ProcessInfo.processInfo.environment["VPNSYNC_PREVIEW"] else { return }
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        switch what {
        case "settings":
            NotificationCenter.default.post(name: .vpnSyncOpenSettings, object: nil)
        case "servers": m.showServers = true
        case "addserver": m.showAddServer = true
        case "edit": m.editServer = m.server
        case "add": m.showAddDevice = true
        case "batch": m.showBatchAdd = true
        case "qr": m.qrDevice = m.devices.first { $0.qr != nil }
        case "limit":
            if let d = ProcessInfo.processInfo.environment["VPNSYNC_PREVIEW_DEVICE"] ?? m.devices.first?.name {
                m.limitTarget = LimitTarget(server: m.server, device: d)
            }
        default: break
        }
    }
}

extension Notification.Name {
    static let vpnSyncOpenSettings = Notification.Name("vpnSyncOpenSettings")
}

/// Opens Settings when asked (test hook), using SwiftUI's own openSettings action.
struct SettingsOpener: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .vpnSyncOpenSettings)) { _ in openSettings() }
    }
}
