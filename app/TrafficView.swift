// The Traffic tab: today's data in a donut, a mirrored speed chart (download above the line,
// upload below), key figures, and devices/protocols ranked by data with split bars.
import SwiftUI
import Charts

/// Download/upload colours (validated categorical slots 1–2, per appearance).
enum TrafficColor {
    static func down(_ dark: Bool) -> Color { dark ? Color(hex: 0x3987E5) : Color(hex: 0x2A78D6) }
    static func up(_ dark: Bool) -> Color { dark ? Color(hex: 0xD95926) : Color(hex: 0xEB6834) }
    /// Devices online (categorical slot 3, aqua) and server traffic per day (slot 7, violet).
    static func online(_ dark: Bool) -> Color { dark ? Color(hex: 0x199E70) : Color(hex: 0x1BAF7A) }
    static func daily(_ dark: Bool) -> Color { dark ? Color(hex: 0x9085E9) : Color(hex: 0x6250D6) }
}

extension Model {
    var history: [TrafficPoint] { live?.history ?? [] }
    var trafficStats: TrafficStats { live?.stats ?? TrafficStats() }
    var serverTotals: ServerTotals? { live?.serverTotals }
    var serverDaily: [DayTraffic] { (live?.serverDaily.values.map { $0 } ?? []).sorted { $0.day < $1.day } }
    func deviceHistory(_ name: String) -> [TrafficPoint] { live?.deviceHistory[name] ?? [] }

    private var pinnedSet: Set<String> {
        Set((UserDefaults.standard.string(forKey: "pinned") ?? "").split(separator: "\n").map(String.init))
    }
    func isPinned(_ device: String) -> Bool { pinnedSet.contains("\(server)/\(device)") }
    func togglePin(_ device: String) {
        var p = pinnedSet
        let k = "\(server)/\(device)"
        if p.contains(k) { p.remove(k) } else { p.insert(k) }
        UserDefaults.standard.set(p.sorted().joined(separator: "\n"), forKey: "pinned")
        objectWillChange.send()
    }
}

struct TrafficView: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    @AppStorage("rateUnit") private var rateUnit = "bytes"
    @State private var range: Double = 900           // seconds shown in the chart
    @State private var hover: TrafficPoint?
    @State private var hoverOnline: TrafficPoint?
    @State private var hoverDay: DayTraffic?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    donut
                    chart
                }
                figures
                HStack(alignment: .top, spacing: 12) {
                    onlineChart
                    dailyChart
                }
                HStack(alignment: .top, spacing: 12) {
                    ranked(title: "By device", rows: m.trafficStats.devices, pinnable: true)
                    ranked(title: "By protocol", rows: m.trafficStats.protocols, pinnable: false)
                        .frame(width: 230)
                }
                usageSection
                Text("Today's figures count from when VPN Sync started watching \(m.server) and reset at midnight. Server totals, usage and limits come from the server itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .id("bottom")
            }
            .padding(2)
        }
        .scrollIndicators(.never)
        .onAppear {   // test hook: VPNSYNC_TRAFFIC_SCROLL=bottom, for screenshots
            if ProcessInfo.processInfo.environment["VPNSYNC_TRAFFIC_SCROLL"] == "bottom" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .onChange(of: m.usage) {   // the usage section arrives later and makes the page taller
            if ProcessInfo.processInfo.environment["VPNSYNC_TRAFFIC_SCROLL"] == "bottom" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        }
    }

    // MARK: donut

    private var donut: some View {
        let total = m.trafficStats.total
        let frac = total.total > 0 ? Double(total.down) / Double(total.total) : 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("VPN data today").font(.system(.callout, design: .rounded).weight(.semibold))
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                if total.total > 0 {
                    Circle().trim(from: 0, to: frac - 0.004)
                        .stroke(TrafficColor.down(t.dark), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                    Circle().trim(from: frac + 0.004, to: 1)
                        .stroke(TrafficColor.up(t.dark), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(formatBytes(total.total)).font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("total").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 118, height: 118)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("VPN data today \(formatBytes(total.total)): download \(formatBytes(total.down)), upload \(formatBytes(total.up))")
            VStack(alignment: .leading, spacing: 4) {
                legendRow(color: TrafficColor.down(t.dark), label: "Download", value: formatBytes(total.down))
                legendRow(color: TrafficColor.up(t.dark), label: "Upload", value: formatBytes(total.up))
            }
        }
        .padding(14)
        .frame(width: 190)
        .glassPanel(20)
    }

    private func legendRow(color: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 12, height: 4)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(.caption, design: .rounded).weight(.medium)).monospacedDigit()
        }
    }

    // MARK: chart

    private var visible: [TrafficPoint] {
        guard let last = m.history.last?.time else { return [] }
        return m.history.filter { $0.time >= last.addingTimeInterval(-range) }
    }

    private var chart: some View {
        let pts = visible
        let maxV = max(pts.map { max($0.down, $0.up) }.max() ?? 0, 1024)
        let now = pts.last
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Speed").font(.system(.callout, design: .rounded).weight(.semibold)).fixedSize()
                Spacer()
                Picker("Range", selection: $range) {
                    Text("5 min").tag(300.0); Text("15 min").tag(900.0); Text("1 h").tag(3600.0)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 14) {
                // legend + live readout (direct labels for the two series)
                legendChip(TrafficColor.down(t.dark), "Download", now.map { formatRate($0.down) } ?? "–")
                legendChip(TrafficColor.up(t.dark), "Upload", now.map { formatRate($0.up) } ?? "–")
                Spacer()
                Picker("Units", selection: $rateUnit) { Text("MB/s").tag("bytes"); Text("Mbit/s").tag("bits") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .controlSize(.small)
                    .help("Show speeds in bytes or bits per second")
            }
            if pts.count < 2 {
                Text(m.monitoring ? "Collecting speed samples…" : "Turn on Live to record speeds.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("Time", p.time), y: .value("Speed", p.down), series: .value("Direction", "Download"))
                            .foregroundStyle(TrafficColor.down(t.dark).opacity(0.22))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Speed", p.down), series: .value("Direction", "Download"))
                            .foregroundStyle(TrafficColor.down(t.dark))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Time", p.time), y: .value("Speed", -p.up), series: .value("Direction", "Upload"))
                            .foregroundStyle(TrafficColor.up(t.dark).opacity(0.22))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Speed", -p.up), series: .value("Direction", "Upload"))
                            .foregroundStyle(TrafficColor.up(t.dark))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                    if let h = hover {
                        RuleMark(x: .value("Time", h.time))
                            .foregroundStyle(Color.primary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                                    legendRow(color: TrafficColor.down(t.dark), label: "Download", value: formatRate(h.down))
                                    legendRow(color: TrafficColor.up(t.dark), label: "Upload", value: formatRate(h.up))
                                }
                                .padding(8)
                                .frame(width: 170)
                                .glassPanel(10)
                            }
                    }
                }
                .chartYScale(domain: -maxV * 1.1 ... maxV * 1.1)
                .chartXScale(domain: (pts.last!.time.addingTimeInterval(-range))...pts.last!.time)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [-maxV, -maxV / 2, 0, maxV / 2, maxV]) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(formatRate(abs(d))).font(.caption2) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel(format: .dateTime.hour().minute()).font(.caption2)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = loc.x - geo[plot].origin.x
                                    if let date: Date = proxy.value(atX: x) {
                                        hover = pts.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
                                    }
                                case .ended: hover = nil
                                }
                            }
                    }
                }
                .frame(minHeight: 150)
                .accessibilityLabel("Speed over the last \(Int(range / 60)) minutes. Download above the line, upload below.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassPanel(20)
    }

    private func legendChip(_ color: Color, _ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 4)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .fixedSize()
    }

    // MARK: devices online

    private var onlineChart: some View {
        let pts = visible
        let now = pts.last
        let top = max(pts.map(\.online).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Devices online").font(.system(.callout, design: .rounded).weight(.semibold))
                Spacer()
                Text(now.map { String(localized: "\($0.online) now") } ?? "–")
                    .font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if pts.count < 2 {
                Text("Collecting…").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("Time", p.time), y: .value("Devices", p.online))
                            .foregroundStyle(TrafficColor.online(t.dark).opacity(0.22))
                            .interpolationMethod(.stepEnd)
                        LineMark(x: .value("Time", p.time), y: .value("Devices", p.online))
                            .foregroundStyle(TrafficColor.online(t.dark))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.stepEnd)
                    }
                    if let h = hoverOnline {
                        RuleMark(x: .value("Time", h.time))
                            .foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(h.time.formatted(date: .omitted, time: .shortened)): \(h.online) online")
                                    .font(.caption).padding(6).glassPanel(8)
                            }
                    }
                }
                .chartXScale(domain: (pts.last!.time.addingTimeInterval(-range))...pts.last!.time)
                .chartYScale(domain: 0...(Double(top) + 0.5))
                .chartYAxis {
                    AxisMarks(position: .leading, values: Array(stride(from: 0, through: top, by: max(1, top / 3)))) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute()).font(.caption2)
                    }
                }
                .chartOverlay { proxy in hoverLayer(proxy) { date in
                    hoverOnline = date.flatMap { d in pts.min { abs($0.time.timeIntervalSince(d)) < abs($1.time.timeIntervalSince(d)) } }
                } }
                .frame(height: 110)
                .accessibilityLabel("Devices online over the last \(Int(range / 60)) minutes, \(now?.online ?? 0) now")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassPanel(20)
    }

    // MARK: server traffic per day

    private var dailyChart: some View {
        let days = m.serverDaily
        let today = TrafficStats.today()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Server traffic per day").font(.system(.callout, design: .rounded).weight(.semibold))
                Spacer()
                if let d = hoverDay ?? days.last {
                    let dayLabel = d.day == today ? String(localized: "Today") : d.date.formatted(.dateTime.month(.abbreviated).day())
                    Text("\(dayLabel): \(formatBytes(d.total))")
                        .font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if days.isEmpty {
                Text("Builds up day by day from the server's own counter.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart {
                    ForEach(days) { d in
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("Traffic", Double(d.total)), width: .ratio(0.7))
                            .foregroundStyle(TrafficColor.daily(t.dark).opacity(hoverDay == nil || hoverDay == d ? 1 : 0.45))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    }
                }
                .chartXScale(domain: Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
                             ... Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let b = v.as(Double.self) { Text(formatBytes(Int64(b))).font(.caption2) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2)
                    }
                }
                .chartOverlay { proxy in hoverLayer(proxy) { date in
                    guard let date else { hoverDay = nil; return }
                    let key = { () -> String in
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
                        return f.string(from: date)
                    }()
                    hoverDay = days.first { $0.day == key }
                } }
                .frame(height: 110)
                .help(hoverDay.map { String(localized: "In \(formatBytes($0.rx)), out \(formatBytes($0.tx))") } ?? String(localized: "All network traffic of the server per day, counted by vnstat"))
                .accessibilityLabel("Server traffic per day for the last 30 days")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassPanel(20)
    }

    /// Hover tracking over a chart: reports the date under the pointer (nil when it leaves).
    private func hoverLayer(_ proxy: ChartProxy, _ onDate: @escaping (Date?) -> Void) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        guard let plot = proxy.plotFrame else { return }
                        onDate(proxy.value(atX: loc.x - geo[plot].origin.x))
                    case .ended: onDate(nil)
                    }
                }
        }
    }

    // MARK: sparkline

    @ViewBuilder private func sparkline(_ name: String) -> some View {
        Sparkline(history: m.deviceHistory(name), name: name)
    }

    // MARK: figures

    private var figures: some View {
        let s = m.trafficStats
        return HStack(spacing: 10) {
            figure("Peak speed today", formatRate(s.peakDown), "download")
            figure("Connections today", "\(s.connections)", s.connections == 1 ? "connect" : "connects")
            figure("Most online at once", "\(s.maxOnline)", s.maxOnline == 1 ? "device" : "devices")
            if let st = m.serverTotals {
                figure("Server this month", formatBytes(st.monthRx + st.monthTx), "today \(formatBytes(st.todayRx + st.todayTx))")
                    .help("All network traffic of \(m.server) (\(st.iface)), counted by vnstat: in \(formatBytes(st.monthRx)), out \(formatBytes(st.monthTx)) this month")
            } else {
                figure("Server this month", "–", "counting starts after a few minutes")
            }
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String, _ note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(16)
    }

    // MARK: usage and limits (counted by the server every minute)

    /// Devices with usage this month, a limit or a pause: paused first, then by this month's data.
    private var usageRows: [(name: String, usage: DeviceUsage)] {
        guard let u = m.usage else { return [] }
        let names = Set(u.usage.filter { $0.value.month > 0 }.keys).union(u.limits.keys).union(u.paused.keys)
        return names.map { ($0, u.usage[$0] ?? DeviceUsage()) }.sorted { a, b in
            let pa = u.paused[a.name] != nil, pb = u.paused[b.name] != nil
            if pa != pb { return pa }
            if a.usage.month != b.usage.month { return a.usage.month > b.usage.month }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var usageSection: some View {
        let rows = usageRows
        let top = max(rows.map(\.usage.month).max() ?? 1, 1)
        let monthTotal = rows.reduce(Int64(0)) { $0 + $1.usage.month }
        let limited = m.usage?.limits.count ?? 0, paused = m.usage?.paused.count ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage and limits").font(.system(.callout, design: .rounded).weight(.semibold))
                Spacer()
                if m.usage != nil {
                    let limitText = limited == 1 ? String(localized: "\(limited) limit") : String(localized: "\(limited) limits")
                    let monthText = String(localized: "\(formatBytes(monthTotal)) this month, \(limitText)")
                    Text(paused > 0 ? String(localized: "\(monthText), \(paused) paused") : monthText)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if m.usage == nil {
                Text(m.monitoring ? "Waiting for \(m.server)'s usage report. If it doesn't arrive, run Set Up for \(m.server) to install usage tracking."
                                  : "Turn on Live to see each device's data and limits.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if rows.isEmpty {
                Text("No data counted this month yet. Set a limit from a device's menu on the Devices tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { row in usageRow(row.name, row.usage, top: top) }
            if !rows.isEmpty {
                HStack(spacing: 14) {
                    legendDot(TrafficColor.down(t.dark), "Download this month")
                    legendDot(TrafficColor.up(t.dark), "Upload this month")
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(20)
    }

    private func usageRow(_ name: String, _ u: DeviceUsage, top: Int64) -> some View {
        let limit = m.usageLimit(name), pause = m.pauseInfo(name)
        return HStack(alignment: .top, spacing: 10) {
            DeviceAvatar(name: name, online: m.lastSnapshot == nil ? nil : m.isOnline(name), size: 24, kind: m.deviceKind(name))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
                    if let pause { PausedBadge(info: pause) }
                    Spacer()
                    Text("\(formatBytes(u.today)) today").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(formatBytes(u.month)).font(.system(.caption, design: .rounded).weight(.medium)).monospacedDigit()
                        .frame(minWidth: 62, alignment: .trailing)
                }
                splitBar(ByteCount(down: u.monthDown, up: u.monthUp), top: top)
                if let limit, let (f, text) = limit.tightest(u) {
                    HStack(spacing: 8) {
                        UsageMeter(fraction: f, width: 70)
                        Text(f >= 1 ? String(localized: "\(text), reached") : limit.pauses ? String(localized: "\(text), pauses at 100%") : String(localized: "\(text), alerts only"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
            }
            Menu { LimitMenuItems(m: m, server: m.server, name: name) } label: {
                LucideIcon("ellipsis", size: 13).foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            .fullLabelMenu()
            .disabled(m.busy)
            .accessibilityLabel("Limit options for \(name)")
        }
        .help("This month: download \(formatBytes(u.monthDown)), upload \(formatBytes(u.monthUp)). Today: \(formatBytes(u.today)).")
    }

    private func legendDot(_ c: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 10, height: 5)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: ranked lists

    private func ranked(title: LocalizedStringKey, rows: [String: ByteCount], pinnable: Bool) -> some View {
        let sorted = rows.sorted { a, b in
            let pa = pinnable && m.isPinned(a.key), pb = pinnable && m.isPinned(b.key)
            if pa != pb { return pa }
            return a.value.total > b.value.total
        }
        let top = max(sorted.map(\.value.total).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(.callout, design: .rounded).weight(.semibold))
            if sorted.isEmpty {
                Text("No traffic counted yet today.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sorted, id: \.key) { row in
                HStack(spacing: 10) {
                    if pinnable {
                        Button { m.togglePin(row.key) } label: {
                            LucideIcon("star", size: 13).foregroundStyle(m.isPinned(row.key) ? Color.yellow : Color.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help(m.isPinned(row.key) ? "Unpin" : "Pin to the top")
                        .accessibilityLabel(m.isPinned(row.key) ? "Unpin \(row.key)" : "Pin \(row.key)")
                        DeviceAvatar(name: row.key, online: nil, size: 24, kind: m.deviceKind(row.key))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.key).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
                            Spacer()
                            if pinnable { sparkline(row.key) }
                            Text(formatBytes(row.value.total)).font(.system(.caption, design: .rounded).weight(.medium)).monospacedDigit()
                        }
                        splitBar(row.value, top: top)
                    }
                }
                .help("Download \(formatBytes(row.value.down)), upload \(formatBytes(row.value.up))")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(20)
    }

    /// Bar length = share of the top row; split into download then upload with a 2 px gap.
    private func splitBar(_ c: ByteCount, top: Int64) -> some View {
        GeometryReader { g in
            let w = g.size.width * CGFloat(Double(c.total) / Double(top))
            let dw = c.total > 0 ? w * CGFloat(Double(c.down) / Double(c.total)) : 0
            HStack(spacing: 2) {
                if c.down > 0 { Capsule().fill(TrafficColor.down(t.dark)).frame(width: max(dw - 1, 3)) }
                if c.up > 0 { Capsule().fill(TrafficColor.up(t.dark)).frame(width: max(w - dw - 1, 3)) }
            }
        }
        .frame(height: 5)
    }
}

/// A device's speed over the last 15 minutes, mirrored like the main chart: download (blue)
/// above a faint centre line, upload (orange) below, on one scale. Used in the Traffic tab and
/// the menu bar panel.
struct Sparkline: View {
    @Environment(\.theme) private var t
    let history: [TrafficPoint]
    let name: String
    var width: CGFloat = 70
    var height: CGFloat = 22

    var body: some View {
        if history.count >= 2 && !history.contains(where: { $0.down > 0 || $0.up > 0 }) {
            // connected but no traffic in the window: say so instead of drawing flat lines
            Text("idle").font(.caption2).foregroundStyle(.tertiary)
                .frame(width: width, height: height)
                .help("No traffic in the last 15 minutes")
        } else if history.count >= 2 {
            let top = max(history.map { max($0.down, $0.up) }.max() ?? 1, 1)
            Chart {
                ForEach(history) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Speed", p.down), series: .value("Direction", "Download"))
                        .foregroundStyle(TrafficColor.down(t.dark))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.time), y: .value("Speed", -p.up), series: .value("Direction", "Upload"))
                        .foregroundStyle(TrafficColor.up(t.dark))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.15)).lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: -top...top)
            .frame(width: width, height: height)
            .help(helpText)
            .accessibilityLabel("Speed of \(name), last 15 minutes: download above the line, upload below")
        }
    }

    private var helpText: String {
        let d = history.map(\.down).max() ?? 0, u = history.map(\.up).max() ?? 0
        return String(localized: "Last 15 minutes. Download (blue, above) peak \(formatRate(d)); upload (orange, below) peak \(formatRate(u)).")
    }
}
