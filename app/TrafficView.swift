// The Traffic tab: today's data in a donut, a mirrored speed chart (download above the line,
// upload below), key figures, and devices/protocols ranked by data with split bars.
import SwiftUI
import Charts

/// Download/upload colours (validated categorical slots 1–2, per appearance).
enum TrafficColor {
    static func down(_ dark: Bool) -> Color { dark ? Color(hex: 0x3987E5) : Color(hex: 0x2A78D6) }
    static func up(_ dark: Bool) -> Color { dark ? Color(hex: 0xD95926) : Color(hex: 0xEB6834) }
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .binary
    return f.string(fromByteCount: b)
}

extension Model {
    var history: [TrafficPoint] { live?.history ?? [] }
    var trafficStats: TrafficStats { live?.stats ?? TrafficStats() }
    var serverTotals: ServerTotals? { live?.serverTotals }

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    donut
                    chart
                }
                figures
                HStack(alignment: .top, spacing: 12) {
                    ranked(title: "By device", rows: m.trafficStats.devices, pinnable: true)
                    ranked(title: "By protocol", rows: m.trafficStats.protocols, pinnable: false)
                        .frame(width: 230)
                }
                Text("Today's figures count from when VPN Sync started watching \(m.server) and reset at midnight. Server totals come from the server itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(2)
        }
        .scrollIndicators(.never)
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

    private func legendRow(color: Color, label: String, value: String) -> some View {
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

    private func legendChip(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 4)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .fixedSize()
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

    private func figure(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(16)
    }

    // MARK: ranked lists

    private func ranked(title: String, rows: [String: ByteCount], pinnable: Bool) -> some View {
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
