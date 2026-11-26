// Data usage, limits and pausing. Each server counts every device's traffic per day (vpn-usage,
// every minute) and reports it in the live stream as USAGEAT/USAGE/LIMIT/PAUSED lines. A limit
// either only alerts, or alerts and pauses the device: its traffic is blocked on the server while
// it stays connected. Alerts fire at 80% and 100%, once per device, limit and period.
import SwiftUI

struct DeviceUsage: Equatable {
    var todayDown: Int64 = 0, todayUp: Int64 = 0, monthDown: Int64 = 0, monthUp: Int64 = 0
    var today: Int64 { todayDown + todayUp }
    var month: Int64 { monthDown + monthUp }
}
struct UsageLimit: Equatable {
    var daily: Int64 = 0, monthly: Int64 = 0
    var pauses = false            // false: alert only
}
struct PauseInfo: Equatable {
    var reason: String            // manual, daily, monthly
    var since: String             // yyyy-mm-dd
    var label: String {
        switch reason {
        case "daily": return "Paused: daily limit reached. Back at midnight."
        case "monthly": return "Paused: monthly limit reached. Back on the 1st."
        default: return "Paused by you"
        }
    }
}

/// One complete report from a server.
struct UsageState: Equatable {
    var time = Date()
    var day = ""                  // the server's "today", in this Mac's time zone once a limit was set
    var usage: [String: DeviceUsage] = [:]
    var limits: [String: UsageLimit] = [:]
    var paused: [String: PauseInfo] = [:]

    /// Feeds one report line; returns false for lines that aren't part of a report.
    mutating func apply(_ f: [String]) -> Bool {
        func n(_ i: Int) -> Int64 { Int64(f[safe: i] ?? "") ?? 0 }
        switch f.first ?? "" {
        case "USAGEAT":
            time = Date(timeIntervalSince1970: TimeInterval(n(1))); day = f[safe: 2] ?? ""
        case "USAGE" where f.count >= 6:
            usage[f[1]] = DeviceUsage(todayDown: n(2), todayUp: n(3), monthDown: n(4), monthUp: n(5))
        case "LIMIT" where f.count >= 5:
            limits[f[1]] = UsageLimit(daily: n(2), monthly: n(3), pauses: f[4] == "pause")
        case "PAUSED" where f.count >= 4:
            paused[f[1]] = PauseInfo(reason: f[2], since: f[3])
        default:
            return false
        }
        return true
    }

    static func parse(_ text: String) -> UsageState? {
        var u = UsageState(), seen = false
        for line in text.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            if f.first == "USAGEAT" { seen = true }
            if seen { _ = u.apply(f) }
        }
        return seen ? u : nil
    }
}

extension Model {
    var usage: UsageState? { usageByServer[server] }
    func deviceUsage(_ name: String) -> DeviceUsage? { usage?.usage[name] }
    func usageLimit(_ name: String) -> UsageLimit? { usage?.limits[name] }
    func pauseInfo(_ name: String) -> PauseInfo? { usage?.paused[name] }

    /// A new report arrived (from the live stream or after a change).
    func setUsage(_ u: UsageState, server s: String) {
        let old = usageByServer[s]
        guard old != u else { return }
        usageByServer[s] = u
        checkUsageAlerts(u, server: s, previous: old)
    }

    /// Fetches the report now (after a change, or when live monitoring is off).
    func refreshUsage(_ s: String? = nil) async {
        let s = s ?? server
        guard !s.isEmpty else { return }
        let (code, out) = await runCLI(["usage", s, "--raw"], quiet: true)
        if code == 0, let u = UsageState.parse(out) { setUsage(u, server: s) }
    }

    func setPaused(_ name: String, _ pause: Bool) async {
        let s = server
        let (code, out) = await cli([pause ? "pause" : "resume", s, name], label: "\(pause ? "Pausing" : "Resuming") \(name)…")
        if code == 0 {
            notices = [pause ? "\(name) is paused: it stays connected but gets no internet until you resume it."
                             : "\(name) is back online."]
            status = .upToDate
        } else {
            status = .failed("\(pause ? "Pause" : "Resume") failed: \(lastLines(out, 2))")
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
        let (code, out) = await cli(args, label: limit == nil ? "Removing the limit…" : "Saving the limit…")
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
                guard pct >= 0.8 else { continue }
                let level = pct >= 1 ? 100 : 80
                let key = "\(s)/\(name)/\(period == "day" ? u.day : month)/\(period)/\(level)"
                guard !sent.contains(key) else { continue }
                sent.append(key); changed = true
                // 100% replaces the 80% alert of the same period
                if level == 100 { sent.append(key.replacingOccurrences(of: "/100", with: "/80")) }
                guard notify else { continue }
                let what = period == "day" ? "daily" : "monthly"
                let span = period == "day" ? "today" : "this month"
                let title: String, body: String
                if level == 100 {
                    title = "\(name) reached its \(what) limit"
                    body = limit.pauses
                        ? "\(formatBytes(value)) used \(span) on \(s). Its internet is paused until \(period == "day" ? "midnight" : "the 1st"); you can resume it in VPN Sync."
                        : "\(formatBytes(value)) of \(formatBytes(cap)) used \(span) on \(s)."
                } else {
                    title = "\(name) used \(Int(pct * 100))% of its \(what) limit"
                    body = "\(formatBytes(value)) of \(formatBytes(cap)) \(span) on \(s)."
                        + (limit.pauses ? " It will be paused at 100%." : "")
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
                if let limit, let (frac, text) = tightest(u ?? DeviceUsage(), limit) {
                    UsageMeter(fraction: frac)
                        .help(text)
                    Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    private func summary(_ u: DeviceUsage) -> String {
        "\(formatBytes(u.today)) today, \(formatBytes(u.month)) this month"
    }

    /// The limit closest to being reached.
    private func tightest(_ u: DeviceUsage, _ l: UsageLimit) -> (Double, String)? {
        var best: (Double, String)?
        if l.daily > 0 {
            let f = Double(u.today) / Double(l.daily)
            best = (f, "\(Int(min(f, 9.99) * 100))% of \(formatBytes(l.daily)) a day")
        }
        if l.monthly > 0 {
            let f = Double(u.month) / Double(l.monthly)
            if best == nil || f > best!.0 { best = (f, "\(Int(min(f, 9.99) * 100))% of \(formatBytes(l.monthly)) a month") }
        }
        return best
    }
}

/// A small capsule meter: accent below 80%, orange from 80%, red at 100%.
struct UsageMeter: View {
    let fraction: Double
    var width: CGFloat = 54
    var body: some View {
        let f = max(0, min(1, fraction))
        let color: Color = fraction >= 1 ? .red : fraction >= 0.8 ? .orange : .accentColor
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
        if !dailyOn && !monthlyOn { return "Turn on a daily or a monthly limit." }
        if dailyOn && bytes(dailyValue, dailyUnit) == nil { return "Enter the daily limit as a number, e.g. 2 or 1.5." }
        if monthlyOn && bytes(monthlyValue, monthlyUnit) == nil { return "Enter the monthly limit as a number, e.g. 50." }
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
                limitRow("Daily limit", on: $dailyOn, value: $dailyValue, unit: $dailyUnit, used: used.today)
                limitRow("Monthly limit", on: $monthlyOn, value: $monthlyValue, unit: $monthlyUnit, used: used.month)
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
                Text("You're notified at 80% and 100%. A paused device stays connected but gets no internet until midnight (daily) or the 1st (monthly); you can resume it early from its menu. Days follow this Mac's time zone.")
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
