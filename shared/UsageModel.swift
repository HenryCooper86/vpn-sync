// Shared by the Mac and iPhone apps (Foundation only).
// Data usage, limits and pauses as each server reports them (vpn-usage: USAGEAT / USAGE / LIMIT /
// PAUSED lines), and the limit events that follow from two reports.
import Foundation

/// The early-warning level in percent (Settings → Limits); 0 turns it off.
var usageWarnAt: Int { UserDefaults.standard.object(forKey: "usageWarnAt") as? Int ?? 80 }
/// The warning level as a fraction, or nil when it's off.
var usageWarnFraction: Double? { usageWarnAt > 0 ? Double(usageWarnAt) / 100 : nil }

struct DeviceUsage: Equatable {
    var todayDown: Int64 = 0, todayUp: Int64 = 0, monthDown: Int64 = 0, monthUp: Int64 = 0
    var today: Int64 { todayDown + todayUp }
    var month: Int64 { monthDown + monthUp }
}
struct UsageLimit: Equatable {
    var daily: Int64 = 0, monthly: Int64 = 0
    var pauses = false            // false: alert only

    /// "1.5 GB a day and 20 GB a month, pauses at 100%"
    var summary: String {
        let tail = pauses ? String(localized: "pauses at 100%") : String(localized: "alerts only")
        if daily > 0, monthly > 0 { return String(localized: "\(formatBytes(daily)) a day and \(formatBytes(monthly)) a month, \(tail)") }
        if daily > 0 { return String(localized: "\(formatBytes(daily)) a day, \(tail)") }
        if monthly > 0 { return String(localized: "\(formatBytes(monthly)) a month, \(tail)") }
        return tail
    }

    /// The limit closest to being reached: fraction used and "86% of 1.5 GB a day".
    func tightest(_ u: DeviceUsage) -> (fraction: Double, text: String)? {
        var best: (fraction: Double, text: String)?
        if daily > 0 {
            let f = Double(u.today) / Double(daily)
            best = (f, String(localized: "\(Int(min(f, 9.99) * 100))% of \(formatBytes(daily)) a day"))
        }
        if monthly > 0 {
            let f = Double(u.month) / Double(monthly)
            if best == nil || f > best!.fraction { best = (f, String(localized: "\(Int(min(f, 9.99) * 100))% of \(formatBytes(monthly)) a month")) }
        }
        return best
    }
}
struct PauseInfo: Equatable {
    var reason: String            // manual, daily, monthly
    var since: String             // yyyy-mm-dd
    var label: String {
        switch reason {
        case "daily": String(localized: "Paused: daily limit reached. Back at midnight.")
        case "monthly": String(localized: "Paused: monthly limit reached. Back on the 1st.")
        default: String(localized: "Paused by you")
        }
    }
}

/// Something that happened to a device's limit or pause, for the Activity list.
struct UsageEvent: Identifiable, Equatable {
    enum Kind: Equatable { case nearing, reached, paused, resumed, limitSet, limitRemoved }
    let id = UUID()
    let time: Date
    let device: String
    let kind: Kind
    let text: String              // "used 80% of its daily limit"
    let detail: String            // "1.2 GB of 1.5 GB today"

    /// What changed between two reports from the same server. The first report after launch
    /// has nothing to compare with, so it adds no events.
    static func changes(from old: UsageState, to new: UsageState) -> [UsageEvent] {
        var out: [UsageEvent] = []
        func add(_ n: String, _ k: Kind, _ text: String, _ detail: String = "") {
            out.append(UsageEvent(time: new.time, device: n, kind: k, text: text, detail: detail))
        }
        let sameDay = old.day == new.day, sameMonth = old.day.prefix(7) == new.day.prefix(7)
        let names = Set(old.limits.keys).union(new.limits.keys).union(old.paused.keys).union(new.paused.keys)
        for n in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let ol = old.limits[n], nl = new.limits[n], op = old.paused[n], np = new.paused[n]
            let ou = old.usage[n] ?? DeviceUsage(), nu = new.usage[n] ?? DeviceUsage()
            if ol != nl {
                if let nl { add(n, .limitSet, ol == nil ? String(localized: "got a usage limit") : String(localized: "has a new usage limit"), nl.summary) }
                else { add(n, .limitRemoved, String(localized: "has no usage limit now")) }
            } else if let nl {
                // crossings of an unchanged limit; a pausing limit's 100% shows as the pause below
                for (what, cap, was, now, same) in [("daily", nl.daily, ou.today, nu.today, sameDay),
                                                    ("monthly", nl.monthly, ou.month, nu.month, sameMonth)] where cap > 0 {
                    let isDaily = what == "daily"
                    let a = same ? Double(was) / Double(cap) : 0, b = Double(now) / Double(cap)
                    let detail = isDaily ? String(localized: "\(formatBytes(now)) of \(formatBytes(cap)) today")
                                         : String(localized: "\(formatBytes(now)) of \(formatBytes(cap)) this month")
                    let tailPause = nl.pauses ? String(localized: ", pauses at 100%") : ""
                    if a < 1, b >= 1 {
                        if !nl.pauses { add(n, .reached, isDaily ? String(localized: "reached its daily limit") : String(localized: "reached its monthly limit"), detail + String(localized: ", alerts only")) }
                    } else if let w = usageWarnFraction, a < w, b >= w {
                        add(n, .nearing, isDaily ? String(localized: "used \(Int(b * 100))% of its daily limit") : String(localized: "used \(Int(b * 100))% of its monthly limit"), detail + tailPause)
                    }
                }
            }
            if op == nil, let np {
                switch np.reason {
                case "daily":
                    add(n, .paused, String(localized: "was paused at its daily limit"),
                        String(localized: "\(formatBytes(nu.today)) today, back at midnight"))
                case "monthly":
                    add(n, .paused, String(localized: "was paused at its monthly limit"),
                        String(localized: "\(formatBytes(nu.month)) this month, back on the 1st"))
                default:
                    add(n, .paused, String(localized: "was paused by you"), String(localized: "stays connected, no internet"))
                }
            } else if let op, np == nil {
                let lifted = (op.reason == "daily" && !sameDay) || (op.reason == "monthly" && !sameMonth)
                let resumedDetail: String
                if lifted { resumedDetail = op.reason == "daily" ? String(localized: "a new day started") : String(localized: "a new month started") }
                else if op.reason == "manual" { resumedDetail = "" }
                else { resumedDetail = op.reason == "daily" ? String(localized: "won't be paused again today") : String(localized: "won't be paused again this month") }
                add(n, .resumed, lifted ? String(localized: "has internet again") : String(localized: "was resumed"), resumedDetail)
            }
        }
        return out
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
