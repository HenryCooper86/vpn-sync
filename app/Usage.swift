// Data usage, limits and pausing. Each server counts every device's traffic per day (vpn-usage,
// every minute) and reports it in the live stream as USAGEAT/USAGE/LIMIT/PAUSED lines. A limit
// either only alerts, or alerts and pauses the device: its traffic is blocked on the server while
// it stays connected. Alerts fire at the warning level (80% unless changed in Settings) and at
// 100%, once per device, limit and period.
import SwiftUI

extension Model {
    var usage: UsageState? { usageByServer[server] }
    func deviceUsage(_ name: String) -> DeviceUsage? { usage?.usage[name] }
    func usageLimit(_ name: String) -> UsageLimit? { usage?.limits[name] }
    func pauseInfo(_ name: String) -> PauseInfo? { usage?.paused[name] }
    /// Every server's devices that are paused, and those at or over the warning level (not paused).
    var limitAttention: (paused: Int, near: Int) {
        var p = 0, n = 0
        for s in servers {
            guard let u = usageByServer[s] else { continue }
            p += u.paused.count
            n += u.limits.filter { name, l in
                u.paused[name] == nil && (l.tightest(u.usage[name] ?? DeviceUsage())?.fraction ?? 0) >= (usageWarnFraction ?? .infinity)
            }.count
        }
        return (p, n)
    }
    /// "1 paused, 2 at 80% or more", or nil when nothing needs attention.
    var limitAttentionText: String? {
        let a = limitAttention
        let parts = [a.paused == 0 ? nil : String(localized: "\(a.paused) paused"),
                     a.near == 0 ? nil : String(localized: "\(a.near) at \(warnAt)% or more")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: clauseSep)
    }

    /// Menu bar panel opened with Live off: fetch reports older than 5 minutes.
    func refreshStaleUsage() async {
        guard !monitoring else { return }
        for s in servers where (usageByServer[s]?.time).map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            await refreshUsage(s)
        }
    }

    /// The selected server's limit events, newest first.
    var limitEvents: [UsageEvent] { usageEvents[server] ?? [] }
    /// Connects, disconnects and limit events on the selected server.
    var activityCount: Int { events.count + limitEvents.count }

    /// A new report arrived (from the live stream or after a change).
    func setUsage(_ u: UsageState, server s: String) {
        let old = usageByServer[s]
        guard old != u else { return }
        usageByServer[s] = u
        if let old {
            let new = UsageEvent.changes(from: old, to: u)
            if !new.isEmpty {
                var list = new.reversed() + (usageEvents[s] ?? [])
                if list.count > 200 { list.removeLast(list.count - 200) }
                usageEvents[s] = list
            }
        }
        checkUsageAlerts(u, server: s, previous: old)
    }

    /// Fetches the report now (after a change, or when live monitoring is off).
    /// Returns false when the server didn't answer or has no usage tracking yet.
    @discardableResult
    func refreshUsage(_ s: String? = nil) async -> Bool {
        let s = s ?? server
        guard !s.isEmpty else { return false }
        let (code, out) = await runCLI(["usage", s, "--raw"], quiet: true)
        guard code == 0, let u = UsageState.parse(out) else { return false }
        setUsage(u, server: s)
        return true
    }

    func setPaused(_ name: String, _ pause: Bool, server: String? = nil) async {
        let s = server ?? self.server
        let (code, out) = await cli([pause ? "pause" : "resume", s, name], label: pause ? String(localized: "Pausing \(name)…") : String(localized: "Resuming \(name)…"))
        if code == 0 {
            notices = [pause ? String(localized: "\(name) is paused: it stays connected but gets no internet until you resume it.")
                             : String(localized: "\(name) is back online.")]
            status = .upToDate
        } else {
            status = .failed(pause ? String(localized: "Pause failed: \(lastLines(out, 2))") : String(localized: "Resume failed: \(lastLines(out, 2))"))
        }
        await refreshUsage(s)
    }

    /// Saves a limit (nil clears it). Returns an error message, or nil.
    func saveLimit(_ name: String, server s: String, _ limit: UsageLimit?) async -> String? {
        var args = ["limit", s, name]
        if let l = limit {
            args += ["--daily", String(l.daily), "--monthly", String(l.monthly), "--action", l.pauses ? "pause" : "alert"]
        } else {
            args.append("--clear")
        }
        let (code, out) = await cli(args, label: limit == nil ? String(localized: "Removing the limit…") : String(localized: "Saving the limit…"))
        await refreshUsage(s)
        if code != 0 { return lastLines(out, 2) }
        status = .upToDate
        return nil
    }

    // MARK: alerts

    private static let alertKey = "usageAlertsSent"

    func checkUsageAlerts(_ u: UsageState, server s: String, previous: UsageState?) {
        var sent = UserDefaults.standard.stringArray(forKey: Self.alertKey) ?? []
        let month = String(u.day.prefix(7))
        var changed = false
        for (name, limit) in u.limits {
            let used = u.usage[name] ?? DeviceUsage()
            for (period, cap, value) in [("day", limit.daily, used.today), ("month", limit.monthly, used.month)] where cap > 0 {
                let pct = Double(value) / Double(cap)
                guard pct >= (usageWarnFraction ?? 1) else { continue }
                let level = pct >= 1 ? 100 : usageWarnAt
                let key = "\(s)/\(name)/\(period == "day" ? u.day : month)/\(period)/\(level)"
                guard !sent.contains(key) else { continue }
                sent.append(key); changed = true
                // 100% replaces the warning of the same period
                if level == 100, usageWarnAt > 0 { sent.append(key.replacingOccurrences(of: "/100", with: "/\(usageWarnAt)")) }
                guard limitAlerts else { continue }
                let isDay = period == "day"
                let title: String, body: String
                if level == 100 {
                    title = isDay ? String(localized: "\(name) reached its daily limit") : String(localized: "\(name) reached its monthly limit")
                    if limit.pauses {
                        body = isDay
                            ? String(localized: "\(formatBytes(value)) used today on \(s). Its internet is paused until midnight; you can resume it in VPN Sync.")
                            : String(localized: "\(formatBytes(value)) used this month on \(s). Its internet is paused until the 1st; you can resume it in VPN Sync.")
                    } else {
                        body = isDay
                            ? String(localized: "\(formatBytes(value)) of \(formatBytes(cap)) used today on \(s).")
                            : String(localized: "\(formatBytes(value)) of \(formatBytes(cap)) used this month on \(s).")
                    }
                } else {
                    let pctInt = Int(pct * 100)
                    title = isDay ? String(localized: "\(name) used \(pctInt)% of its daily limit") : String(localized: "\(name) used \(pctInt)% of its monthly limit")
                    let base = isDay
                        ? String(localized: "\(formatBytes(value)) of \(formatBytes(cap)) today on \(s).")
                        : String(localized: "\(formatBytes(value)) of \(formatBytes(cap)) this month on \(s).")
                    body = limit.pauses ? base + " " + String(localized: "It will be paused at 100%.") : base
                }
                Notifier.shared.postInfo(id: "\(s)/usage/\(name)/\(period)", title: title, body: body)
            }
        }
        if changed {
            if sent.count > 300 { sent.removeFirst(sent.count - 300) }
            UserDefaults.standard.set(sent, forKey: Self.alertKey)
        }
    }
}

// MARK: - Views

/// "1.2 GB today, 8.4 GB this month", a meter for the tightest limit, under a device's name.
struct UsageLine: View {
    @EnvironmentObject var m: Model
    let name: String

    var body: some View {
        let u = m.deviceUsage(name), limit = m.usageLimit(name)
        if u != nil || limit != nil {
            HStack(spacing: 8) {
                Text(summary(u ?? DeviceUsage()))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                if let limit, let (frac, text) = limit.tightest(u ?? DeviceUsage()) {
                    UsageMeter(fraction: frac)
                        .help(text)
                    Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    private func summary(_ u: DeviceUsage) -> String {
        String(localized: "\(formatBytes(u.today)) today, \(formatBytes(u.month)) this month")
    }
}

/// Pause/Resume and limit actions for one device (row menus in the panel and Traffic tab).
struct LimitMenuItems: View {
    @ObservedObject var m: Model
    let server: String
    let name: String
    var beforeEdit: () -> Void = {}
    /// Opens the limit sheet somewhere else (Settings) instead of in the main window.
    var onEdit: ((LimitTarget) -> Void)? = nil
    var body: some View {
        let u = m.usageByServer[server]
        if u?.paused[name] != nil {
            Button("Resume Internet") { Task { await m.setPaused(name, false, server: server) } }.disabled(m.busy)
        } else {
            Button("Pause Internet") { Task { await m.setPaused(name, true, server: server) } }.disabled(m.busy)
        }
        Button(u?.limits[name] == nil ? "Set Usage Limit…" : "Edit Usage Limit…") {
            let t = LimitTarget(server: server, device: name)
            if let onEdit { onEdit(t) } else { beforeEdit(); m.limitTarget = t }
        }
        if u?.limits[name] != nil {
            Button("Remove Limit") { Task { _ = await m.saveLimit(name, server: server, nil) } }.disabled(m.busy)
        }
    }
}

/// "Paused" capsule; the tooltip says why and until when.
struct PausedBadge: View {
    let info: PauseInfo
    var body: some View {
        Label("Paused", lucide: "pause", size: 10)
            .labelStyle(TightLabel())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .help(info.label)
    }
}

/// Menu bar panel: every device on a server that has a limit or is paused, closest to its
/// limit first, with Pause/Resume and limit actions.
struct PanelLimits: View {
    @ObservedObject var m: Model
    let server: String
    let openMain: () -> Void

    private var names: [String] {
        guard let u = m.usageByServer[server] else { return [] }
        func frac(_ n: String) -> Double {
            u.limits[n]?.tightest(u.usage[n] ?? DeviceUsage())?.fraction ?? 0
        }
        return Set(u.limits.keys).union(u.paused.keys).sorted {
            let p0 = u.paused[$0] != nil, p1 = u.paused[$1] != nil
            if p0 != p1 { return p0 }
            if frac($0) != frac($1) { return frac($0) > frac($1) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        let list = names
        if !list.isEmpty, let u = m.usageByServer[server] {
            VStack(alignment: .leading, spacing: 6) {
                Text("Limits").font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                ForEach(list, id: \.self) { n in row(n, u) }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func row(_ n: String, _ u: UsageState) -> some View {
        let used = u.usage[n] ?? DeviceUsage()
        let limit = u.limits[n]
        HStack(spacing: 8) {
            Text(n).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
            if let p = u.paused[n] { PausedBadge(info: p) }
            Spacer(minLength: 6)
            if let (f, text) = limit?.tightest(used) {
                Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                UsageMeter(fraction: f, width: 44)
            } else {
                Text("\(formatBytes(used.today)) today").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                LimitMenuItems(m: m, server: server, name: n, beforeEdit: openMain)
            } label: { LucideIcon("ellipsis", size: 13).foregroundStyle(.secondary).frame(width: 18, height: 18) }
                .fullLabelMenu()
                .disabled(m.busy)
                .accessibilityLabel("Limit options for \(n)")
        }
        .help("\(formatBytes(used.today)) today, \(formatBytes(used.month)) this month")
    }
}

/// A small capsule meter: accent below the warning level, orange from it, red at 100%.
struct UsageMeter: View {
    let fraction: Double
    var width: CGFloat = 54
    var body: some View {
        let f = max(0, min(1, fraction))
        let color: Color = fraction >= 1 ? .red : fraction >= (usageWarnFraction ?? 1) ? .orange : .accentColor
        ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(0.12))
            Capsule().fill(color).frame(width: max(f > 0 ? 4 : 0, width * f))
        }
        .frame(width: width, height: 5)
        .accessibilityElement()
        .accessibilityLabel("Usage")
        .accessibilityValue("\(Int(fraction * 100)) percent of the limit")
    }
}

struct LimitTarget: Identifiable { let server: String; let device: String; var id: String { server + "/" + device } }

struct LimitSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    let target: LimitTarget

    enum Unit: String, CaseIterable, Identifiable { case mb = "MB", gb = "GB"; var id: String { rawValue } }

    private var alertText: String {
        guard m.limitAlerts else { return String(localized: "Notifications for limits are off (Settings → Limits).") }
        return m.warnAt > 0 ? String(localized: "You're notified at \(m.warnAt)% and 100%.") : String(localized: "You're notified at 100%.")
    }

    @State private var dailyOn = false
    @State private var dailyValue = "2"
    @State private var dailyUnit = Unit.gb
    @State private var monthlyOn = false
    @State private var monthlyValue = "50"
    @State private var monthlyUnit = Unit.gb
    @State private var pauses = false
    @State private var working = false
    @State private var error: String?
    @State private var loaded = false

    private var existing: UsageLimit? { m.usageByServer[target.server]?.limits[target.device] }
    private var used: DeviceUsage { m.usageByServer[target.server]?.usage[target.device] ?? DeviceUsage() }

    private func bytes(_ v: String, _ u: Unit) -> Int64? {
        guard let d = Double(v.replacingOccurrences(of: ",", with: ".")), d > 0, d < 1_000_000 else { return nil }
        return Int64(d * (u == .gb ? 1_073_741_824 : 1_048_576))
    }
    private var problem: String? {
        if !dailyOn && !monthlyOn { return String(localized: "Turn on a daily or a monthly limit.") }
        if dailyOn && bytes(dailyValue, dailyUnit) == nil { return String(localized: "Enter the daily limit as a number, e.g. 2 or 1.5.") }
        if monthlyOn && bytes(monthlyValue, monthlyUnit) == nil { return String(localized: "Enter the monthly limit as a number, e.g. 50.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LucideIcon("gauge", size: 20).foregroundStyle(.secondary)
                Text("Usage Limit for \(target.device)").font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Text("\(formatBytes(used.today)) used today, \(formatBytes(used.month)) this month on \(target.server). Counted on the server every minute, in both directions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                limitRow(String(localized: "Daily limit"), on: $dailyOn, value: $dailyValue, unit: $dailyUnit, used: used.today)
                limitRow(String(localized: "Monthly limit"), on: $monthlyOn, value: $monthlyValue, unit: $monthlyUnit, used: used.month)
            }
            .padding(14)
            .glassPanel(16)

            VStack(alignment: .leading, spacing: 6) {
                Text("When it reaches the limit").font(.headline)
                Picker("When it reaches the limit", selection: $pauses) {
                    Text("Notify me").tag(false)
                    Text("Notify me and pause its internet").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("\(alertText) A paused device stays connected but gets no internet until midnight (daily) or the 1st (monthly); you can resume it early from its menu. Days follow this Mac's time zone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let p = (problem != nil && (dailyOn || monthlyOn)) ? problem : nil {
                Text(p).font(.caption).foregroundStyle(.red)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                if existing != nil {
                    Button("Remove Limit", role: .destructive) { save(nil) }
                        .glassButton()
                        .disabled(working)
                }
                if working { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Save Limit") {
                    save(UsageLimit(daily: dailyOn ? bytes(dailyValue, dailyUnit) ?? 0 : 0,
                                    monthly: monthlyOn ? bytes(monthlyValue, monthlyUnit) ?? 0 : 0,
                                    pauses: pauses))
                }
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .disabled(working || problem != nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .glassSheet()
        .onAppear(perform: load)
        .task { await m.refreshUsage(target.server); if !loaded { load() } }
    }

    @ViewBuilder
    private func limitRow(_ title: String, on: Binding<Bool>, value: Binding<String>, unit: Binding<Unit>, used: Int64) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 104, alignment: .leading)
            Toggle(title, isOn: on).toggleStyle(.switch).controlSize(.small).labelsHidden()
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .disabled(!on.wrappedValue)
                .accessibilityLabel("\(title) amount")
            Picker("", selection: unit) { ForEach(Unit.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 70)
                .disabled(!on.wrappedValue)
                .accessibilityLabel("\(title) unit")
            Spacer()
            if on.wrappedValue, let cap = bytes(value.wrappedValue, unit.wrappedValue) {
                UsageMeter(fraction: Double(used) / Double(cap), width: 60)
            }
        }
    }

    private func load() {
        guard let l = existing else { return }
        loaded = true
        func split(_ b: Int64) -> (String, Unit) {
            let gb = Double(b) / 1_073_741_824
            if gb >= 1 { return (trim(gb), .gb) }
            return (trim(Double(b) / 1_048_576), .mb)
        }
        func trim(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression) }
        if l.daily > 0 { dailyOn = true; (dailyValue, dailyUnit) = split(l.daily) }
        if l.monthly > 0 { monthlyOn = true; (monthlyValue, monthlyUnit) = split(l.monthly) }
        pauses = l.pauses
    }

    private func save(_ l: UsageLimit?) {
        guard !working else { return }
        working = true; error = nil
        Task {
            let err = await m.saveLimit(target.device, server: target.server, l)
            working = false
            if let err { error = err } else { dismiss() }
        }
    }
}
