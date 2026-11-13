import Foundation

/// A calendar date (Python's `date`): days since 1970-01-01, so arithmetic and weekdays are exact.
struct Day: Hashable, Comparable, Sendable {
    let ordinal: Int

    init(ordinal: Int) { self.ordinal = ordinal }

    /// nil for an invalid date.
    init?(_ y: Int, _ m: Int, _ d: Int) {
        guard (1...9999).contains(y), (1...12).contains(m), (1...Day.daysIn(y, m)).contains(d) else { return nil }
        // days_from_civil (Howard Hinnant)
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        ordinal = era * 146097 + doe - 719468
    }

    var ymd: (y: Int, m: Int, d: Int) {
        let z = ordinal + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    var year: Int { ymd.y }
    var month: Int { ymd.m }
    var day: Int { ymd.d }

    /// `isoweekday()`: Monday 1 … Sunday 7.
    var isoWeekday: Int { ((ordinal % 7) + 7 + 3) % 7 + 1 }

    func adding(_ days: Int) -> Day { Day(ordinal: ordinal + days) }

    /// `date.replace(year=)`; nil for 29 Feb in a common year (Python raises ValueError).
    func replacing(year: Int) -> Day? { Day(year, month, day) }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

    static func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    static func daysIn(_ y: Int, _ m: Int) -> Int {
        [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    }

    /// `date.fromisoformat(s)` for "YYYY-MM-DD".
    static func parse(_ s: String) -> Day? {
        let c = Array(s.unicodeScalars)
        guard c.count == 10, c[4] == "-", c[7] == "-" else { return nil }
        guard let y = AulaTime.digits(c, 0, 4), let m = AulaTime.digits(c, 5, 2), let d = AulaTime.digits(c, 8, 2) else { return nil }
        return Day(y, m, d)
    }

    static let monthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}

/// Aula's timestamps and "today", in Europe/Copenhagen (aula/utils/dates.py and mapping.py's helpers).
enum AulaTime {
    static let zone = TimeZone(identifier: "Europe/Copenhagen")!

    static func digits(_ c: [Unicode.Scalar], _ at: Int, _ count: Int) -> Int? {
        guard at + count <= c.count else { return nil }
        var v = 0
        for k in at..<(at + count) {
            guard ("0"..."9").contains(c[k]) else { return nil }
            v = v * 10 + Int(c[k].value - 48)
        }
        return v
    }

    /// A parsed ISO 8601 timestamp (`datetime.fromisoformat`), fractions dropped.
    struct Stamp: Sendable {
        var day: Day
        var seconds: Int  // since local midnight
        var offset: Int?  // seconds east of UTC; nil = naive

        /// Seconds since the epoch; a naive stamp is read as Copenhagen time.
        var epoch: Int {
            let local = day.ordinal * 86400 + seconds
            if let offset { return local - offset }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let (y, m, d) = day.ymd
            let comps = DateComponents(year: y, month: m, day: d, hour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60)
            return Int(cal.date(from: comps)?.timeIntervalSince1970 ?? Double(local - 3600))
        }
    }

    /// `parse_api_datetime`: offset, "Z" or naive; nil for anything unreadable or not a string.
    static func parse(_ value: Any?) -> Stamp? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let c = Array(s.unicodeScalars)
        guard c.count >= 10, let day = Day.parse(String(String.UnicodeScalarView(c[0..<10]))) else { return nil }
        if c.count == 10 { return Stamp(day: day, seconds: 0, offset: nil) }
        // Any single character may separate date and time.
        var i = 11
        guard let h = digits(c, i, 2), h < 24 else { return nil }
        i += 2
        var mi = 0, sec = 0
        if i < c.count, c[i] == ":" {
            guard let v = digits(c, i + 1, 2), v < 60 else { return nil }
            mi = v
            i += 3
            if i < c.count, c[i] == ":" {
                guard let v = digits(c, i + 1, 2), v < 60 else { return nil }
                sec = v
                i += 3
                if i < c.count, c[i] == "." || c[i] == "," {
                    i += 1
                    let start = i
                    while i < c.count, ("0"..."9").contains(c[i]) { i += 1 }
                    if i == start { return nil }
                }
            }
        }
        var offset: Int?
        if i < c.count {
            if c[i] == "Z" {
                offset = 0
                i += 1
            } else if c[i] == "+" || c[i] == "-" {
                let sign = c[i] == "-" ? -1 : 1
                guard let oh = digits(c, i + 1, 2) else { return nil }
                i += 3
                var om = 0
                if i < c.count, c[i] == ":" {
                    guard let v = digits(c, i + 1, 2) else { return nil }
                    om = v
                    i += 3
                } else if let v = digits(c, i, 2) {
                    om = v
                    i += 2
                }
                guard oh < 24, om < 60 else { return nil }
                offset = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        guard i == c.count else { return nil }
        return Stamp(day: day, seconds: h * 3600 + mi * 60 + sec, offset: offset)
    }

    /// Copenhagen wall time of an instant.
    static func local(_ epoch: Int) -> (day: Day, seconds: Int, offset: Int) {
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epoch)))
        let local = epoch + offset
        let day = Int((Double(local) / 86400).rounded(.down))
        return (Day(ordinal: day), local - day * 86400, offset)
    }

    static func format(day: Day, seconds: Int, offset: Int, withSeconds: Bool = true) -> String {
        let sign = offset < 0 ? "-" : "+"
        let o = abs(offset)
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return "\(day.iso)T\(time)\(sign)\(String(format: "%02d:%02d", o / 3600, o / 60 % 60))"
    }

    /// mapping.iso: any Aula timestamp -> ISO 8601 in Copenhagen with offset, to the second.
    static func iso(_ value: Any?) -> String? {
        guard let stamp = parse(value) else { return nil }
        let l = local(stamp.epoch)
        return format(day: l.day, seconds: l.seconds, offset: l.offset)
    }

    /// The instant "today" and "now" are read from; tests pin it (`Aula.$clock`).
    static func now() -> Date { Aula.clock ?? Date() }

    /// `aula_today()`.
    static func today() -> Day { local(Int(now().timeIntervalSince1970.rounded(.down))).day }

    /// Minutes since midnight in Copenhagen (`now().hour * 60 + now().minute`).
    static func nowMinutes() -> Int { local(Int(now().timeIntervalSince1970.rounded(.down))).seconds / 60 }

    /// `datetime.combine(day, time, TZ).isoformat()` for 00:00:00 or 23:59:59.999999.
    static func combine(_ day: Day, endOfDay: Bool) -> String {
        let seconds = endOfDay ? 86399 : 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let (y, m, d) = day.ymd
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60))!
        let offset = zone.secondsFromGMT(for: date)
        let base = format(day: day, seconds: seconds, offset: offset)
        guard endOfDay else { return base }
        let split = base.index(base.startIndex, offsetBy: 19)
        return base[..<split] + ".999999" + base[split...]
    }
}

extension Aula {
    /// Pins "now" for tests (the goldens were recorded at a fixed instant).
    @TaskLocal static var clock: Date?
}
