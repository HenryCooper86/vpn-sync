// Traffic (speed, data this month per device, the server per day) and Activity (connects,
// disconnects and limit events while the app is open).
import SwiftUI
import Charts

struct TrafficSection: View {
    @ObservedObject var live: ServerLive

    var body: some View {
        VStack(spacing: 14) {
            speed
            if let t = live.totals { totalsCard(t) }
            perDevice
            if !live.days.isEmpty { perDay }
        }
    }

    private var speed: some View {
        let last = live.history.last
        let top = max(live.history.map { max($0.down, $0.up) }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speed").font(.headline)
                Spacer()
                Text("last 15 minutes").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                legend(Palette.download, "Download", last.map { formatRate($0.down) } ?? "–")
                legend(Palette.upload, "Upload", last.map { formatRate($0.up) } ?? "–")
            }
            if live.history.count > 1 {
                Chart {
                    ForEach(live.history) { p in
                        AreaMark(x: .value("Time", p.time), y: .value("Speed", p.down), series: .value("Direction", "Download"), stacking: .unstacked)
                            .foregroundStyle(Palette.download.opacity(0.25)).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Speed", p.down), series: .value("Direction", "Download"))
                            .foregroundStyle(Palette.download).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                        AreaMark(x: .value("Time", p.time), y: .value("Speed", -p.up), series: .value("Direction", "Upload"), stacking: .unstacked)
                            .foregroundStyle(Palette.upload.opacity(0.25)).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Speed", -p.up), series: .value("Direction", "Upload"))
                            .foregroundStyle(Palette.upload).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 0.5))
                }
                .chartYScale(domain: -top...top)
                .chartYAxis {
                    AxisMarks(values: [-top, 0, top]) { v in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(formatRate(abs(d))).font(.caption2) } }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 5)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                    AxisValueLabel(format: .dateTime.hour().minute())
                } }
                .frame(height: 170)
                .accessibilityLabel("Speed over the last 15 minutes; download above the line, upload below")
            } else {
                Text("Collecting…").font(.caption).foregroundStyle(.secondary).frame(height: 60)
            }
        }
        .card()
    }

    private func legend(_ c: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(c).frame(width: 12, height: 4)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    private func totalsCard(_ t: ServerTotals) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Server today").font(.caption).foregroundStyle(.secondary)
                Text(formatBytes(t.todayRx + t.todayTx)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("This month").font(.caption).foregroundStyle(.secondary)
                Text(formatBytes(t.monthRx + t.monthTx)).font(.title3.weight(.semibold)).monospacedDigit()
            }
        }
        .card()
    }

    /// Each device's data this month (the server's own count), split down/up, on one scale.
    private var perDevice: some View {
        let rows = (live.usage?.usage ?? [:]).filter { $0.value.month > 0 }.sorted { $0.value.month > $1.value.month }
        let top = max(rows.first?.value.month ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Data this month").font(.headline)
            if rows.isEmpty {
                Text(live.usage == nil ? "Waiting for the server's usage report…" : "No data yet this month.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.key) { n, u in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(n).font(.subheadline.weight(.medium))
                        if live.usage?.paused[n] != nil { Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.caption) }
                        Spacer()
                        Text(formatBytes(u.month)).font(.subheadline).monospacedDigit()
                    }
                    GeometryReader { g in
                        let w = g.size.width * CGFloat(Double(u.month) / Double(top))
                        let down = u.month > 0 ? w * CGFloat(Double(u.monthDown) / Double(u.month)) : 0
                        HStack(spacing: 2) {
                            Capsule().fill(Palette.download).frame(width: max(down, u.monthDown > 0 ? 3 : 0))
                            Capsule().fill(Palette.upload).frame(width: max(w - down - 2, u.monthUp > 0 ? 3 : 0))
                        }
                    }
                    .frame(height: 6)
                    if let l = live.usage?.limits[n], let t = l.tightest(u) {
                        HStack { UsageMeter(fraction: t.fraction, width: 70); Text(t.text).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    private var perDay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server traffic per day").font(.headline)
            Chart(live.days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Data", d.total))
                    .foregroundStyle(Palette.ikev2.gradient).cornerRadius(3)
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel { if let b = v.as(Int64.self) { Text(formatBytes(b)).font(.caption2) } }
            } }
            .frame(height: 140)
        }
        .card()
    }
}

struct ActivitySection: View {
    @ObservedObject var live: ServerLive

    private enum Item: Identifiable {
        case conn(LiveEvent), limit(UsageEvent)
        var id: UUID { switch self { case .conn(let e): return e.id; case .limit(let e): return e.id } }
        var time: Date { switch self { case .conn(let e): return e.time; case .limit(let e): return e.time } }
    }

    var body: some View {
        let items = (live.events.map(Item.conn) + live.usageEvents.map(Item.limit)).sorted { $0.time > $1.time }
        if items.isEmpty {
            Text("Connects, disconnects and usage-limit events show up here while the app is open.")
                .font(.callout).foregroundStyle(.secondary).card()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item).padding(.vertical, 8)
                    Divider()
                }
            }
            .card(22, padding: 14)
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.time.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            switch item {
            case .conn(let e):
                StatusDot(color: e.connected ? Palette.online : .secondary, on: e.connected, size: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(e.device).bold()) \(e.connected ? "connected" : "disconnected")")
                    Text("\(e.vpn)\(e.ip == "-" ? "" : " from \(e.ip)")").font(.caption).foregroundStyle(.secondary)
                }
            case .limit(let e):
                Image(systemName: icon(e.kind)).font(.caption).foregroundStyle(color(e.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(e.device).bold()) \(e.text)")
                    if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .font(.subheadline)
    }

    private func icon(_ k: UsageEvent.Kind) -> String {
        switch k {
        case .nearing, .reached, .limitSet, .limitRemoved: return "gauge.with.dots.needle.67percent"
        case .paused: return "pause.fill"
        case .resumed: return "checkmark.circle.fill"
        }
    }
    private func color(_ k: UsageEvent.Kind) -> Color {
        switch k {
        case .nearing, .paused: return .orange
        case .reached: return .red
        case .resumed: return Palette.online
        case .limitSet, .limitRemoved: return .secondary
        }
    }
}
